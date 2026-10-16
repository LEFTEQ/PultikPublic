import AppKit
import CodeThemes
import SwiftUI

/// The code canvas (PR workbench WP2): one AppKit surface for a diff,
/// replacing P7/P10's TextKit chunks. An `NSScrollView` over a flipped
/// document view as tall as the laid-out document, holding one layer per
/// row near the viewport — a row is drawn once, with CoreText, when it comes
/// into view and recycled when it leaves, so scrolling only moves layers
/// (120 fps, AC 4). Long lines wrap under the gutter by default (D9); the
/// file header of the topmost file sticks to the top.
///
/// Never first responder: the search field keeps the keys and
/// `KeyboardCoordinator` routes ↑/↓, ⌥Z and ⌘C here. The selected code theme
/// colours it (`CodePalette`, from `CodeThemeStore`) and a switch repaints it
/// in place; highlighting lands per file as `HighlightCache` answers, and a
/// file draws plain until then.
final class CodeCanvasView: NSView {
    /// The canvas the shown tab draws, for ⌘C and the panel driver.
    static weak var active: CodeCanvasView?

    struct Callbacks {
        /// A header's click (or ↵ on a ringed file): fold or unfold it.
        var toggleFile: (String) -> Void = { _ in }
        /// Files whose rows are near the viewport and have no runs yet.
        var needTokens: ([Int]) -> Void = { _ in }
        /// A gutter click on a line: file index, line index, ⇧ extends.
        var gutter: (Int, Int, Bool) -> Void = { _, _, _ in }
        /// The file at the top of the viewport changed (the tree follows it).
        var topFile: (Int?) -> Void = { _ in }
        /// The pointer rested on a word (or left it): its definition peeks (D2).
        var hover: (CodeWord?) -> Void = { _ in }
        /// ⌘-click on a word: its definition opens as a card (D2).
        var definition: (CodeWord) -> Void = { _ in }
    }

    /// An identifier on the canvas and where it sits.
    struct CodeWord: Equatable {
        let name: String
        let path: String
    }

    /// The word the last click landed on — what F12 and ⇧F12 look up.
    private(set) var lastWord: CodeWord?

    /// The identifier under a document point, if it is on a code line.
    func word(at point: NSPoint) -> CodeWord? {
        guard let hit = location(at: point), case let .line(file, index) = document.rows[hit.row] else { return nil }
        let text = document.files[file].lines[index].text
        // Display columns run over expanded tabs; the word is the line's own.
        let map = DiffDocument.expandTabs(text).map
        let column = map.lastIndex { $0 <= hit.column } ?? 0
        return CodeSearch.wordAt(text, column: min(column, text.utf16.count)).map {
            CodeWord(name: $0, path: document.files[file].path)
        }
    }

    func noteClick(at point: NSPoint) {
        lastWord = word(at: point)
    }

    /// Lines drawn with a gutter mark, by file then line index: a pending
    /// review comment, an open thread (WP4).
    var marks: [Int: Set<Int>] = [:] {
        didSet { if marks != oldValue { canvas.redrawAll() } }
    }

    /// The lines an open review comment is about: washed in the accent.
    var anchor: (file: Int, lines: ClosedRange<Int>)? {
        didSet {
            if anchor?.file != oldValue?.file || anchor?.lines != oldValue?.lines { canvas.redrawAll() }
        }
    }

    private var reportedTopFile: Int??

    let scrollView = NSScrollView()
    private let canvas = CanvasDocumentView()
    private let sticky = StickyHeaderView()
    var callbacks = Callbacks()

    private(set) var document = DiffDocument(nil)
    private(set) var diffLayout: DiffLayout
    private(set) var wraps = true
    /// Each file's runs per side, as they land.
    private var tokens: [Int: [DiffDocument.Side: LineTokens]] = [:]
    private var requested: Set<Int> = []
    var focusedFile: Int? {
        didSet { if focusedFile != oldValue { canvas.redrawHeaders([oldValue, focusedFile]); sticky.needsDisplay = true } }
    }

    private(set) var theme: CodePalette
    private let fonts = CodeFonts(size: 12)
    var font: NSFont { fonts.regular }
    let headerFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    let metaFont = NSFont.systemFont(ofSize: 11)

    override convenience init(frame: NSRect) {
        self.init(frame: frame, themes: CodePreferences.shared.themes)
    }

    init(frame: NSRect, themes: CodeThemeStore) {
        diffLayout = DiffLayout(DiffDocument(nil), width: 600, wraps: true, metrics: .init())
        theme = CodePalette(themes.theme)
        super.init(frame: frame)
        wantsLayer = true
        scrollView.drawsBackground = true
        paintBackground()
        // A switch in Settings repaints every live row here, the PR stays open.
        themes.observe(self) { [weak self] theme in self?.apply(theme) }
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = canvas
        canvas.owner = self
        sticky.owner = self
        addSubview(scrollView)
        addSubview(sticky)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("CodeCanvasView is built in code")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// The selected theme changed: every row near the viewport redraws in
    /// it. Runs are kinds, not colours, so nothing re-highlights.
    func apply(_ theme: CodeTheme) {
        self.theme = CodePalette(theme)
        paintBackground()
        canvas.redrawAll()
        sticky.needsDisplay = true
    }

    private func paintBackground() {
        layer?.backgroundColor = theme.background.cgColor
        scrollView.backgroundColor = theme.background
        scrollView.scrollerKnobStyle = theme.theme.appearance == .light ? .dark : .light
    }

    // MARK: - Content

    /// The metrics this font draws with: the gutter is two figure columns
    /// and the ± marker.
    var metrics: DiffLayout.Metrics {
        var metrics = DiffLayout.Metrics()
        metrics.advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        metrics.codeX = 12 + CGFloat(document.digits * 2 + 3) * metrics.advance
        return metrics
    }

    func show(_ document: DiffDocument, wraps: Bool) {
        let previousTop = topAnchor()
        let sameFiles = document.files.map(\.path) == self.document.files.map(\.path)
        self.document = document
        self.wraps = wraps
        if !sameFiles {
            tokens = [:]
            requested = []
        }
        relayout(keeping: sameFiles ? previousTop : nil)
    }

    func setWraps(_ wraps: Bool) {
        guard wraps != self.wraps else { return }
        let anchor = topAnchor()
        self.wraps = wraps
        relayout(keeping: anchor)
    }

    /// Runs for one side of one file landed: its visible rows redraw.
    func setTokens(_ runs: LineTokens, file: Int, side: DiffDocument.Side) {
        tokens[file, default: [:]][side] = runs
        canvas.redraw(file: file)
    }

    func runs(file: Int, side: DiffDocument.Side) -> LineTokens? {
        tokens[file]?[side]
    }

    /// The row at the top of the viewport and how far into it — kept
    /// across a relayout so a fold or ⌥Z never jumps the reader.
    private func topAnchor() -> (row: Int, offset: CGFloat)? {
        guard !document.rows.isEmpty else { return nil }
        let top = scrollView.contentView.bounds.minY
        let row = diffLayout.row(at: top)
        return (row, top - diffLayout.frame(row).y)
    }

    private func relayout(keeping anchor: (row: Int, offset: CGFloat)?) {
        let width = max(scrollView.contentView.bounds.width, 200)
        diffLayout = DiffLayout(document, width: width, wraps: wraps, metrics: metrics)
        scrollView.hasHorizontalScroller = !wraps
        let widest = wraps ? width : max(width, metrics.codeX + CGFloat(document.columns.max() ?? 0) * metrics.advance + 24)
        canvas.frame = NSRect(x: 0, y: 0, width: widest, height: max(diffLayout.height, scrollView.contentView.bounds.height))
        if let anchor, anchor.row < document.rows.count {
            let y = min(diffLayout.frame(anchor.row).y + anchor.offset, max(0, diffLayout.height - scrollView.contentView.bounds.height))
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: max(0, y)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        canvas.reload()
        updateSticky()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentView.bounds.width
        if abs(width - (layoutWidth ?? 0)) > 0.5 {
            layoutWidth = width
            relayout(keeping: topAnchor())
        }
        updateSticky()
    }

    private var layoutWidth: CGFloat?

    @objc private func scrolled() {
        canvas.updateVisibleRows()
        updateSticky()
    }

    /// Files whose rows sit near the viewport and have no runs yet.
    func requestTokens(for rows: Range<Int>) {
        var files: [Int] = []
        for row in rows {
            let file: Int
            switch document.rows[row] {
            case let .header(index), let .line(index, _), let .note(index, _): file = index
            case .gap: continue
            }
            if files.last != file, !requested.contains(file), document.files[file].language != nil,
               !document.files[file].collapsed {
                files.append(file)
            }
        }
        guard !files.isEmpty else { return }
        requested.formUnion(files)
        callbacks.needTokens(files)
    }

    // MARK: - Sticky header

    /// The header of the file at the top of the viewport, pushed up by the
    /// next file's header as it arrives.
    private func updateSticky() {
        let top = scrollView.contentView.bounds.minY
        let row = document.rows.isEmpty ? 0 : diffLayout.row(at: top)
        // A gap belongs to the file below it.
        let file = document.rows.isEmpty ? nil : fileOf(row) ?? fileOf(min(row + 1, document.rows.count - 1))
        if reportedTopFile != .some(file) {
            reportedTopFile = .some(file)
            let report = callbacks.topFile
            DispatchQueue.main.async { report(file) }
        }
        guard !document.rows.isEmpty, top > 0 else {
            sticky.isHidden = true
            return
        }
        guard let file, let header = document.headerRows[safe: file] else {
            sticky.isHidden = true
            return
        }
        let headerFrame = diffLayout.frame(header)
        guard headerFrame.y < top else {
            sticky.isHidden = true
            return
        }
        let height = diffLayout.metrics.headerHeight
        let next = document.headerRows[safe: file + 1].map { diffLayout.frame($0).y - top } ?? .infinity
        let push = min(0, next - height - diffLayout.metrics.gapHeight)
        let frame = NSRect(x: 0, y: push, width: scrollView.contentView.bounds.width, height: height)
        // Scrolling only moves it; it redraws when its file or size changes.
        if sticky.file != file || sticky.frame.size != frame.size || sticky.isHidden { sticky.needsDisplay = true }
        sticky.file = file
        sticky.frame = frame
        sticky.isHidden = false
    }

    private func fileOf(_ row: Int) -> Int? {
        switch document.rows[row] {
        case let .header(index), let .line(index, _), let .note(index, _): index
        case .gap: nil
        }
    }

    // MARK: - Keys (routed by KeyboardCoordinator)

    func scroll(_ amount: ScrollAmount) {
        let clip = scrollView.contentView
        let bottom = max(0, canvas.frame.height - clip.bounds.height)
        let y = clip.bounds.minY
        let target: CGFloat = switch amount {
        case let .step(sign): y + CGFloat(sign) * diffLayout.metrics.lineHeight * 3
        case let .page(sign): y + CGFloat(sign) * max(diffLayout.metrics.lineHeight * 3, clip.bounds.height - 48)
        case let .edge(sign): sign > 0 ? bottom : 0
        }
        animateScroll(to: min(max(0, target), bottom))
    }

    /// The file's header at the top — ⇥'s ring and the tree's click.
    func scrollTo(file: Int, animated: Bool = true) {
        guard let row = document.headerRows[safe: file] else { return }
        let bottom = max(0, canvas.frame.height - scrollView.contentView.bounds.height)
        let y = min(diffLayout.frame(row).y, bottom)
        if animated { animateScroll(to: y) } else {
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// A new-side line of a file a third of the way down the viewport, its
    /// row washed like a selection; nil = the file's header at the top.
    func scrollTo(file: Int, line: Int?) {
        guard let line, let lines = document.files[safe: file]?.lines,
              let index = lines.firstIndex(where: { $0.new == line }),
              let row = document.rows.firstIndex(of: .line(file: file, index: index)) else {
            return scrollTo(file: file)
        }
        anchor = (file, index ... index)
        let bottom = max(0, canvas.frame.height - scrollView.contentView.bounds.height)
        let y = diffLayout.frame(row).y - scrollView.contentView.bounds.height / 3
        animateScroll(to: min(max(0, y), bottom))
    }

    private func animateScroll(to y: CGFloat) {
        let clip = scrollView.contentView
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.14
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        }
        scrollView.reflectScrolledClipView(clip)
    }

    var hasSelection: Bool { canvas.selection != nil }

    /// ⌘C: the selected lines' own text, tabs as written.
    func copySelection() -> Bool {
        guard let text = canvas.selectedText(), !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    // MARK: - Drawing (one row at a time)

    /// Draws `row` into a flipped context `width` wide, its left edge at
    /// document x `originX` (the gutter stays put when not wrapping).
    func draw(row: Int, in context: CGContext, width: CGFloat, originX: CGFloat, selection: Range<Int>?) {
        guard document.rows.indices.contains(row) else { return }
        let frame = diffLayout.frame(row)
        context.setFillColor(theme.background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: frame.height))
        switch document.rows[row] {
        case .gap:
            break
        case let .header(file):
            drawHeader(file, in: context, width: width, height: frame.height)
        case let .note(_, text):
            drawText(text, font: metaFont, color: theme.muted, at: CGPoint(x: diffLayout.metrics.codeX, y: 0),
                     height: frame.height, in: context)
        case let .line(file, index):
            drawLine(file: file, index: index, in: context, width: width, originX: originX, height: frame.height,
                     selection: selection)
        }
    }

    private func drawLine(file: Int, index: Int, in context: CGContext, width: CGFloat, originX: CGFloat,
                          height: CGFloat, selection: Range<Int>?) {
        let entry = document.files[file]
        let line = entry.lines[index]
        let metrics = diffLayout.metrics
        let (wash, gutter, mark, markColor): (NSColor?, NSColor?, String, NSColor) = switch line.kind {
        case .added: (theme.addedWash, theme.addedGutter, "+", theme.addedMark)
        case .removed: (theme.removedWash, theme.removedGutter, "−", theme.removedMark)
        case .hunk: (theme.hunk, nil, " ", theme.muted)
        case .context, .note: (nil, nil, " ", theme.muted)
        }
        if let wash {
            context.setFillColor(wash.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let gutter {
            context.setFillColor(gutter.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: metrics.codeX - metrics.advance * 1.5, height: height))
        }
        // The lines a review comment is being written about, and lines that
        // already carry one (WP4): the accent is selection.
        if let anchor, anchor.file == file, anchor.lines.contains(index) {
            context.setFillColor(NSColor(Theme.accent).withAlphaComponent(0.16).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if marks[file]?.contains(index) == true {
            context.setFillColor(NSColor(Theme.accent).cgColor)
            context.fill(CGRect(x: 0, y: 3, width: 3, height: height - 6))
        }
        // Gutter: old and new figures, then the marker (colour is never the only signal).
        let digits = document.digits
        let number: (Int?) -> String = { value in
            let figure = value.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, digits - figure.count)) + figure
        }
        if line.kind != .hunk {
            let gutterText = "\(number(line.old)) \(number(line.new))"
            drawText(gutterText, font: font, color: theme.muted, at: CGPoint(x: 8, y: 0),
                     height: metrics.lineHeight, in: context)
            drawText(mark, font: font, color: markColor,
                     at: CGPoint(x: 8 + CGFloat(digits * 2 + 1) * metrics.advance + 2, y: 0),
                     height: metrics.lineHeight, in: context)
        }
        // Code, wrapped at `wrapColumns` under the gutter.
        let (display, map) = DiffDocument.expandTabs(line.text)
        let base: NSColor = line.kind == .hunk || line.kind == .note ? theme.muted : theme.foreground
        let attributed = NSMutableAttributedString(string: display, attributes: [.font: font, .foregroundColor: base])
        let length = attributed.length
        if line.kind != .hunk, line.kind != .note {
            let side = DiffDocument.File.side(line)
            if let source = entry.sourceLine(index, side: side), let runs = tokens[file]?[side]?.runs(line: source) {
                for run in runs {
                    let start = Int(run.start)
                    let end = start + Int(run.length)
                    guard start < map.count else { continue }
                    let from = map[start]
                    let to = map[min(end, map.count - 1)]
                    guard from < to, to <= length, run.kind != .plain else { continue }
                    let range = NSRange(location: from, length: to - from)
                    attributed.addAttribute(.foregroundColor, value: theme.color(run.kind), range: range)
                    let face = theme.font(run.kind, in: fonts)
                    if face !== fonts.regular { attributed.addAttribute(.font, value: face, range: range) }
                }
            }
        }
        // Wrapped rows hold `wrapColumns` columns by the core's width rule (wide
        // chars take two), never a split char: the rows the layout counted.
        let starts = visualStarts(display)
        for (visual, start) in starts.enumerated() {
            let end = visual + 1 < starts.count ? starts[visual + 1] : length
            let y = CGFloat(visual) * metrics.lineHeight
            if let selection {
                let from = max(selection.lowerBound, start)
                let to = min(selection.upperBound, end)
                if from < to || (selection.upperBound > end && from <= to && start < length) {
                    let x0 = metrics.codeX + CGFloat(from - start) * metrics.advance - originX
                    let x1 = metrics.codeX + CGFloat(max(to, from) - start) * metrics.advance - originX
                        + (selection.upperBound > end ? metrics.advance : 0)
                    context.setFillColor(theme.selection.cgColor)
                    context.fill(CGRect(x: x0, y: y, width: max(x1 - x0, 2), height: metrics.lineHeight))
                }
            }
            if end > start {
                let piece = attributed.attributedSubstring(from: NSRange(location: start, length: end - start))
                drawLine(CTLineCreateWithAttributedString(piece), at: CGPoint(x: metrics.codeX - originX, y: y),
                         height: metrics.lineHeight, in: context)
            }
        }
    }

    /// Where each visual row of a line's drawn text starts, in UTF-16 units
    /// (the first at 0); one row when lines do not wrap.
    func visualStarts(_ display: String) -> [Int] {
        guard let wrap = diffLayout.wrapColumns else { return [0] }
        return [0] + DiffDocument.rowStarts(display, columns: wrap)
    }

    func drawHeader(_ file: Int, in context: CGContext, width: CGFloat, height: CGFloat) {
        let entry = document.files[file]
        let changed = entry.changed
        context.setFillColor(theme.header.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(theme.border.cgColor)
        context.fill(CGRect(x: 0, y: height - 1, width: width, height: 1))
        if focusedFile == file {
            context.setStrokeColor(NSColor(Theme.accent).cgColor)
            context.setLineWidth(2)
            context.stroke(CGRect(x: 1, y: 1, width: width - 2, height: height - 2))
        }
        let chevron = entry.lines.isEmpty ? "·" : entry.collapsed ? "▸" : "▾"
        let (glyph, tone): (String, NSColor) = switch changed.status {
        case .added: ("A", theme.addedMark)
        case .removed: ("D", theme.removedMark)
        case .renamed, .copied: ("R", theme.muted)
        default: ("M", theme.muted)
        }
        var x: CGFloat = 10
        x = drawText(chevron, font: headerFont, color: theme.muted, at: CGPoint(x: x, y: 0), height: height, in: context) + 8
        x = drawText(glyph, font: headerFont, color: tone, at: CGPoint(x: x, y: 0), height: height, in: context) + 8
        let counts = "+\(changed.additions) −\(changed.deletions)"
        let countsWidth = (counts as NSString).size(withAttributes: [.font: font]).width
        let path = changed.previousPath.map { "\($0) → \(changed.path)" } ?? changed.path
        let room = width - x - countsWidth - 24
        drawText(Self.truncatedHead(path, font: headerFont, width: room), font: headerFont, color: theme.foreground,
                 at: CGPoint(x: x, y: 0), height: height, in: context)
        let plus = "+\(changed.additions)"
        let plusWidth = (plus as NSString).size(withAttributes: [.font: font]).width
        drawText(plus, font: font, color: theme.addedMark, at: CGPoint(x: width - countsWidth - 12, y: 0),
                 height: height, in: context)
        drawText(" −\(changed.deletions)", font: font, color: theme.removedMark,
                 at: CGPoint(x: width - countsWidth - 12 + plusWidth, y: 0), height: height, in: context)
    }

    /// `…/deep/path/file.ts` — the head goes first, the name stays.
    static func truncatedHead(_ text: String, font: NSFont, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (text as NSString).size(withAttributes: attributes).width > width, width > 20 else { return text }
        var tail = Substring(text)
        while !tail.isEmpty, ("…" + tail as NSString).size(withAttributes: attributes).width > width {
            tail = tail.dropFirst()
        }
        return "…" + tail
    }

    /// One line of text, vertically centred in `height`; returns its right edge.
    @discardableResult
    func drawText(_ text: String, font: NSFont, color: NSColor, at origin: CGPoint, height: CGFloat,
                  in context: CGContext) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color,
        ]))
        drawLine(line, at: origin, height: height, in: context)
        return origin.x + CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func drawLine(_ line: CTLine, at origin: CGPoint, height: CGFloat, in context: CGContext) {
        let ascent = font.ascender
        let descent = -font.descender
        let baseline = origin.y + (height - ascent - descent) / 2 + ascent
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: origin.x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Hit-testing

    /// A row's line and display column at a document point.
    func location(at point: NSPoint) -> (row: Int, column: Int)? {
        guard !document.rows.isEmpty else { return nil }
        let row = diffLayout.row(at: point.y)
        let metrics = diffLayout.metrics
        let visual = Int((point.y - diffLayout.frame(row).y) / metrics.lineHeight)
        let column = max(0, Int(((point.x - metrics.codeX) / metrics.advance).rounded()))
        guard let wrap = diffLayout.wrapColumns else { return (row, column) }
        guard case let .line(file, index) = document.rows[row] else { return (row, visual * wrap + min(column, wrap)) }
        let starts = visualStarts(DiffDocument.expandTabs(document.files[file].lines[index].text).text)
        let start = starts[min(max(visual, 0), starts.count - 1)]
        let width = visual + 1 < starts.count ? starts[visual + 1] - start : wrap
        return (row, start + min(column, width))
    }

    func header(at point: NSPoint) -> Int? {
        guard let hit = location(at: point), case let .header(file) = document.rows[hit.row] else { return nil }
        return file
    }

    func gutterHit(at point: NSPoint) -> (file: Int, index: Int)? {
        guard point.x < diffLayout.metrics.codeX - diffLayout.metrics.advance, let hit = location(at: point),
              case let .line(file, index) = document.rows[hit.row] else { return nil }
        return (file, index)
    }

    // MARK: - Bench (AC 4)

    /// Scrolls top to bottom at `speed` pt/s on the display link and reports
    /// the frame intervals: p99 ≤ 8.3 ms and none over 16.7 ms on ProMotion.
    func runScrollBench(speed: CGFloat, done: @escaping ([String: Any]) -> Void) {
        canvas.benchmark(speed: speed, done: done)
    }

    var lineCount: Int {
        document.rows.reduce(0) { if case .line = $1 { $0 + 1 } else { $0 } }
    }

    /// Files with runs landed on at least one side (the panel driver).
    var highlightedFiles: Int {
        tokens.values.filter { !$0.isEmpty }.count
    }
}

// MARK: - The document view

/// As tall as the laid-out document; holds a layer per row near the
/// viewport and recycles the rest.
final class CanvasDocumentView: NSView {
    weak var owner: CodeCanvasView?
    private var live: [Int: RowLayer] = [:]
    private var spare: [RowLayer] = []
    /// Selection in (row, display column) — anchor and head.
    private(set) var selection: (anchor: (row: Int, column: Int), head: (row: Int, column: Int))?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("CanvasDocumentView is built in code")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    /// Everything changed (a new document, width or wrap): every row redraws.
    func reload() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (_, layer) in live {
            layer.isHidden = true
            spare.append(layer)
        }
        live = [:]
        CATransaction.commit()
        updateVisibleRows()
    }

    func redraw(file: Int) {
        guard let owner else { return }
        for (row, layer) in live {
            switch owner.document.rows[row] {
            case let .line(index, _) where index == file, let .header(index) where index == file:
                layer.setNeedsDisplay()
            default: break
            }
        }
    }

    func redrawAll() {
        for layer in live.values { layer.setNeedsDisplay() }
    }

    func redrawHeaders(_ files: [Int?]) {
        guard let owner else { return }
        for (row, layer) in live {
            if case let .header(file) = owner.document.rows[row], files.contains(file) { layer.setNeedsDisplay() }
        }
    }

    /// Rows within half a viewport of the visible rect get a layer; the
    /// rest go back to the spares.
    func updateVisibleRows() {
        guard let owner, let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.bounds
        let overscan = visible.height * 0.5
        let rows = owner.diffLayout.rows(from: visible.minY - overscan, to: visible.maxY + overscan)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (row, layer) in live where !rows.contains(row) {
            layer.isHidden = true
            spare.append(layer)
            live[row] = nil
        }
        let scale = window?.backingScaleFactor ?? 2
        for row in rows {
            let frame = owner.diffLayout.frame(row)
            let rect = CGRect(x: visible.minX, y: frame.y, width: visible.width, height: frame.height)
            if let layer = live[row] {
                if layer.frame != rect {
                    layer.frame = rect
                    layer.originX = visible.minX
                    layer.setNeedsDisplay()
                }
                continue
            }
            let layer = spare.popLast() ?? makeLayer()
            layer.row = row
            layer.originX = visible.minX
            layer.frame = rect
            layer.contentsScale = scale
            layer.isHidden = false
            layer.setNeedsDisplay()
            live[row] = layer
        }
        CATransaction.commit()
        owner.requestTokens(for: rows)
    }

    private func makeLayer() -> RowLayer {
        let layer = RowLayer()
        layer.canvas = self
        // Every row paints the canvas first: opaque, and 8 bits a channel —
        // the default on a wide-gamut display is 64-bit, twice the fill.
        layer.isOpaque = true
        layer.contentsFormat = .RGBA8Uint
        layer.needsDisplayOnBoundsChange = false
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        self.layer?.addSublayer(layer)
        return layer
    }

    /// The layer asks for its row's pixels.
    func draw(_ layer: RowLayer, in context: CGContext) {
        guard let owner else { return }
        // A sublayer of this flipped view inherits its geometry: y already
        // runs down. Flip only a layer that does not.
        if !layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: layer.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        owner.draw(row: layer.row, in: context, width: layer.bounds.width, originX: layer.originX,
                   selection: selectedColumns(row: layer.row))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        let point = convert(event.locationInWindow, from: nil)
        CodeCanvasView.active = owner
        if let file = owner.header(at: point) {
            owner.callbacks.toggleFile(owner.document.files[file].path)
            return
        }
        if let hit = owner.gutterHit(at: point) {
            owner.callbacks.gutter(hit.file, hit.index, event.modifierFlags.contains(.shift))
            return
        }
        owner.noteClick(at: point)
        if event.modifierFlags.contains(.command), let word = owner.lastWord {
            owner.callbacks.definition(word)
            return
        }
        let previous = selectedRows()
        if let hit = owner.location(at: point) {
            selection = event.modifierFlags.contains(.shift) && selection != nil ? (selection!.anchor, hit) : (hit, hit)
        }
        invalidate(previous, selectedRows())
    }

    // MARK: - Hover (D2's peek)

    private var hoverWork: DispatchWorkItem?
    private var hovered: CodeCanvasView.CodeWord?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    /// The pointer rests 350 ms on a word before it peeks; moving off it
    /// clears the peek at once.
    override func mouseMoved(with event: NSEvent) {
        guard let owner else { return }
        let word = owner.word(at: convert(event.locationInWindow, from: nil))
        hoverWork?.cancel()
        guard word != hovered else { return }
        if word == nil {
            hovered = nil
            owner.callbacks.hover(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hovered = word
            owner.callbacks.hover(word)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    override func mouseExited(with _: NSEvent) {
        hoverWork?.cancel()
        hovered = nil
        owner?.callbacks.hover(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner, let current = selection, let hit = owner.location(at: convert(event.locationInWindow, from: nil))
        else { return }
        let previous = selectedRows()
        selection = (current.anchor, hit)
        autoscroll(with: event)
        invalidate(previous, selectedRows())
    }

    override func mouseUp(with event: NSEvent) {
        // A click without a drag leaves nothing selected.
        if let current = selection, current.anchor == current.head {
            let previous = selectedRows()
            selection = nil
            invalidate(previous, nil)
        }
    }

    private func invalidate(_ old: ClosedRange<Int>?, _ new: ClosedRange<Int>?) {
        for (row, layer) in live where old?.contains(row) == true || new?.contains(row) == true {
            layer.setNeedsDisplay()
        }
    }

    private func ordered() -> (from: (row: Int, column: Int), to: (row: Int, column: Int))? {
        guard let selection else { return nil }
        let a = selection.anchor
        let b = selection.head
        return (a.row, a.column) <= (b.row, b.column) ? (a, b) : (b, a)
    }

    private func selectedRows() -> ClosedRange<Int>? {
        ordered().map { $0.from.row ... $0.to.row }
    }

    /// The display columns of `row` inside the selection; an inner row is
    /// selected to its end (`Int.max`).
    func selectedColumns(row: Int) -> Range<Int>? {
        guard let range = ordered(), range.from.row <= row, row <= range.to.row,
              range.from != range.to || false else { return nil }
        let start = row == range.from.row ? range.from.column : 0
        let end = row == range.to.row ? range.to.column : Int.max
        return start < end ? start ..< end : nil
    }

    /// The selected lines' text as written (tabs, not their spaces).
    func selectedText() -> String? {
        guard let owner, let range = ordered() else { return nil }
        var lines: [String] = []
        for row in range.from.row ... range.to.row {
            guard case let .line(file, index) = owner.document.rows[row], let columns = selectedColumns(row: row)
            else { continue }
            let text = owner.document.files[file].lines[index].text
            let map = DiffDocument.expandTabs(text).map
            let units = Array(text.utf16)
            let from = map.firstIndex { $0 >= columns.lowerBound } ?? units.count
            let to = columns.upperBound == Int.max ? units.count : (map.firstIndex { $0 >= columns.upperBound } ?? units.count)
            lines.append(String(decoding: units[min(from, units.count) ..< max(min(to, units.count), min(from, units.count))],
                                as: UTF16.self))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Bench

    private var bench: (link: CADisplayLink, speed: CGFloat, last: CFTimeInterval?, intervals: [Double],
                        costs: [Double], done: ([String: Any]) -> Void)?

    func benchmark(speed: CGFloat, done: @escaping ([String: Any]) -> Void) {
        guard let clip = enclosingScrollView?.contentView else { return done(["error": "no scroller"]) }
        clip.scroll(to: .zero)
        let link = displayLink(target: self, selector: #selector(benchFrame(_:)))
        bench = (link, speed, nil, [], [], done)
        link.add(to: .main, forMode: .common)
    }

    /// Two figures per frame: the display link's cadence (only meaningful
    /// on a 120 Hz display) and the canvas's own main-thread cost — the
    /// scroll, the rows it places, the new rows drawn — which must fit
    /// 8.3 ms on any display. The rest of the window's commit (the panel's
    /// own animations) is not the canvas's and is left to the frame.
    @objc private func benchFrame(_ link: CADisplayLink) {
        guard var run = bench, let clip = enclosingScrollView?.contentView else { return }
        let started = CACurrentMediaTime()
        let now = link.timestamp
        if let last = run.last { run.intervals.append((now - last) * 1000) }
        let step = run.last.map { CGFloat(now - $0) * run.speed } ?? 0
        run.last = now
        let bottom = max(0, frame.height - clip.bounds.height)
        let y = min(clip.bounds.minY + step, bottom)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        for layer in live.values where layer.needsDisplay() { layer.displayIfNeeded() }
        if step > 0 { run.costs.append((CACurrentMediaTime() - started) * 1000) }
        bench = run
        guard y >= bottom else { return }
        link.invalidate()
        bench = nil
        let stats: ([Double]) -> [String: Any] = { values in
            let sorted = values.sorted()
            let pick: (Double) -> Double = { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
            return ["p50": pick(0.5), "p95": pick(0.95), "p99": pick(0.99), "max": sorted.last ?? 0,
                    "over8_3": sorted.filter { $0 > 8.34 }.count, "over16_7": sorted.filter { $0 > 16.7 }.count]
        }
        run.done(["frames": run.costs.count, "lines": owner?.lineCount ?? 0, "speed": run.speed,
                  "refreshMs": (link.targetTimestamp - link.timestamp) * 1000,
                  "cost": stats(run.costs), "interval": stats(run.intervals)])
    }
}

/// One row's pixels, drawn once and kept while the row is near the viewport.
final class RowLayer: CALayer {
    weak var canvas: CanvasDocumentView?
    var row = 0
    /// The document x the layer's left edge sits at (horizontal scroll).
    var originX: CGFloat = 0

    override func draw(in context: CGContext) {
        canvas?.draw(self, in: context)
    }
}

/// The topmost file's header, pinned over the viewport.
final class StickyHeaderView: NSView {
    weak var owner: CodeCanvasView?
    var file = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func draw(_: NSRect) {
        guard let owner, let context = NSGraphicsContext.current?.cgContext,
              owner.document.files.indices.contains(file) else { return }
        owner.drawHeader(file, in: context, width: bounds.width, height: bounds.height)
    }

    override func mouseDown(with _: NSEvent) {
        guard let owner, owner.document.files.indices.contains(file) else { return }
        owner.callbacks.toggleFile(owner.document.files[file].path)
    }
}

// MARK: - SwiftUI

/// The canvas in a SwiftUI tab. Highlighting never travels through view
/// state: the coordinator asks `HighlightCache` for the files the canvas
/// reports near its viewport and hands the runs straight to it.
struct CodeCanvas: NSViewRepresentable {
    let document: DiffDocument
    /// Changes exactly when `document` does — comparing documents row by
    /// row would cost more than drawing them.
    let documentID: String
    let wraps: Bool
    /// The shown tab of the open detail: it takes ↑/↓ and ⌘C.
    let active: Bool
    let focusedFile: Int?
    let scrollRequest: ScrollRequest?
    /// A blob's text by SHA (the mirror), for whole-file highlighting.
    let blob: @Sendable (String) async throws -> String
    /// A file — and a new-side line in it — to bring up (the tree's click,
    /// a navigation's landing), once per serial.
    var reveal: (file: Int, line: Int?, serial: Int)?
    var marks: [Int: Set<Int>] = [:]
    var anchor: (file: Int, lines: ClosedRange<Int>)?
    var callbacks = CodeCanvasView.Callbacks()

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CodeCanvasView {
        let view = CodeCanvasView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.scrollSerial = scrollRequest?.serial
        return view
    }

    func updateNSView(_ view: CodeCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.blob = blob
        var callbacks = callbacks
        callbacks.needTokens = { [weak coordinator] files in coordinator?.highlight(files) }
        view.callbacks = callbacks
        if coordinator.documentID != documentID {
            coordinator.documentID = documentID
            view.show(document, wraps: wraps)
        } else {
            view.setWraps(wraps)
        }
        view.focusedFile = focusedFile
        view.marks = marks
        view.anchor = anchor
        if let reveal, reveal.serial != coordinator.revealSerial {
            coordinator.revealSerial = reveal.serial
            // A line waits for the document's layout: the next turn has it.
            DispatchQueue.main.async { view.scrollTo(file: reveal.file, line: reveal.line) }
        }
        if active {
            CodeCanvasView.active = view
            if let file = focusedFile, file != coordinator.focusedFile { view.scrollTo(file: file) }
            if let scrollRequest, scrollRequest.serial != coordinator.scrollSerial { view.scroll(scrollRequest.amount) }
        }
        coordinator.focusedFile = focusedFile
        // A request made while another tab was shown is never replayed here.
        coordinator.scrollSerial = scrollRequest?.serial
    }

    static func dismantleNSView(_ view: CodeCanvasView, coordinator: Coordinator) {
        coordinator.cancel()
        if CodeCanvasView.active === view { CodeCanvasView.active = nil }
    }

    @MainActor
    final class Coordinator {
        weak var view: CodeCanvasView?
        var documentID = ""
        var scrollSerial: Int?
        var revealSerial: Int?
        var focusedFile: Int?
        var blob: @Sendable (String) async throws -> String = { _ in "" }
        private var tasks: [Task<Void, Never>] = []

        /// Each side a file draws from, by its blob when the mirror names
        /// one, else by its patch-only text.
        func highlight(_ files: [Int]) {
            guard let view else { return }
            let document = view.document
            let id = documentID
            let blob = blob
            for index in files {
                let file = document.files[index]
                guard let language = file.language else { continue }
                let sides: [DiffDocument.Side] = [.old, .new].filter { side in
                    file.lines.contains { line in
                        switch line.kind {
                        case .context, .added: side == .new
                        case .removed: side == .old
                        case .hunk, .note: false
                        }
                    }
                }
                for side in sides {
                    let sha = side == .new ? file.changed.newBlob : file.changed.oldBlob
                    let key: String
                    let text: @Sendable () async throws -> String
                    if let sha {
                        key = "blob:\(sha):\(language.rawValue)"
                        text = { try await blob(sha) }
                    } else {
                        let fragment = file.sideText(side)
                        key = "patch:\(language.rawValue):\(fragment.utf16.count):\(fragment.hashValue)"
                        text = { fragment }
                    }
                    tasks.append(Task { [weak self] in
                        guard let runs = await HighlightCache.shared.tokens(key: key, language: language, text: text),
                              let self, self.documentID == id else { return }
                        self.view?.setTokens(runs, file: index, side: side)
                    })
                }
            }
        }

        func cancel() {
            tasks.forEach { $0.cancel() }
            tasks = []
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
