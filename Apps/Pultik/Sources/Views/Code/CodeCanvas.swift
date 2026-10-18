import AppKit
import Canvas
import CodeThemes
import SwiftUI

/// The code canvas (PR diff on the shared Rust renderer): one AppKit host for
/// a diff, a `CanvasView` drawing a `DiffEngine` on the shared GPU device.
/// Rust lays the diff out, wraps it under the gutter (D9,
/// docs/specs/2026-10-15-pr-workbench-decisions.md), owns its scroll, sticky
/// header and scroll indicator, its selection and word hits (D3, D4,
/// docs/specs/2026-10-17-pr-diff-rust-canvas-decisions.md); Swift forwards
/// the pointer, keeps the verbs and feeds the highlights. The surface exposes
/// nothing to VoiceOver, as the CoreText rows before it did not (D6, the same
/// record).
///
/// Never first responder: the search field keeps the keys and
/// `KeyboardCoordinator` routes ↑/↓, ⌥Z and ⌘C here. The selected code theme
/// colours it (`CodeThemeStore`) and a switch repaints it in place;
/// highlighting lands per file as `HighlightCache` answers, and a file draws
/// plain until then.
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
        /// The pointer rested on a word (or left it): its definition peeks
        /// (D2, docs/specs/2026-10-15-pr-workbench-decisions.md).
        var hover: (CodeWord?) -> Void = { _ in }
        /// ⌘-click on a word: its definition opens as a card (D2, the same record).
        var definition: (CodeWord) -> Void = { _ in }
    }

    /// An identifier on the canvas and where it sits.
    struct CodeWord: Equatable {
        let name: String
        let path: String
    }

    /// The word the last click landed on — what F12 and ⇧F12 look up.
    private(set) var lastWord: CodeWord?

    /// The identifier under a view point, if it is on a code line.
    func word(at point: NSPoint) -> CodeWord? {
        guard let found = engine?.word(at: Double(point.x), y: Double(point.y)),
              let path = document.files[safe: found.file]?.path else { return nil }
        return CodeWord(name: found.name, path: path)
    }

    func noteClick(at point: NSPoint) {
        lastWord = word(at: point)
    }

    /// Lines drawn with a gutter mark, by file then line index: a pending
    /// review comment, an open thread (WP4).
    var marks: [Int: Set<Int>] = [:] {
        didSet { if marks != oldValue { decorate() } }
    }

    /// The lines an open review comment is about: washed in the accent.
    var anchor: (file: Int, lines: ClosedRange<Int>)? {
        didSet {
            if anchor?.file != oldValue?.file || anchor?.lines != oldValue?.lines { decorate() }
        }
    }

    /// The file ⇥ rings.
    var focusedFile: Int? {
        didSet { if focusedFile != oldValue { decorate() } }
    }

    var callbacks = Callbacks()

    private(set) var document = DiffDocument(nil)
    private(set) var wraps = true
    private(set) var split = false
    private(set) var theme: CodeTheme
    /// The Rust-drawn surface and the engine drawing into it (nil when it refused: logged).
    let surface: CanvasView
    let engine: DiffEngine?
    /// Each file's runs per side, as they land.
    private var tokens: [Int: [DiffDocument.Side: LineTokens]] = [:]
    private var requested: Set<Int> = []
    private var reportedTopFile: Int??
    /// A press that started a selection: its drags and release extend and settle it.
    private var selecting = false
    private var hoverWork: DispatchWorkItem?
    private var hovered: CodeWord?
    private var bench: ScrollBench?

    override convenience init(frame: NSRect) {
        self.init(frame: frame, themes: CodePreferences.shared.themes)
    }

    init(frame: NSRect, themes: CodeThemeStore) {
        theme = themes.theme
        surface = CanvasView(id: "code", background: themes.theme[.background].nsColor)
        do {
            engine = try DiffEngine(theme: themes.theme.id, accent: .theme(Theme.accent))
        } catch {
            NSLog("pultik: code canvas refused theme %@: %@", themes.theme.id, error.localizedDescription)
            engine = nil
        }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = theme[.background].nsColor.cgColor
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        surface.hooks = CanvasView.Hooks(viewed: { [weak self] in self?.viewed() })
        engine?.onMouse = { [weak self] event in self?.mouse(event) ?? false }
        surface.use(engine)
        // A switch in Settings repaints the diff in place, the PR stays open.
        themes.observe(self) { [weak self] theme in self?.apply(theme) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("CodeCanvasView is built in code")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// The selected theme changed: the engine draws in it from the next
    /// frame. Runs are kinds, not colours, so nothing re-highlights.
    func apply(_ theme: CodeTheme) {
        self.theme = theme
        let background = theme[.background].nsColor
        layer?.backgroundColor = background.cgColor
        surface.background = background
        do {
            try engine?.setTheme(id: theme.id, accent: .theme(Theme.accent))
        } catch {
            NSLog("pultik: code canvas refused theme %@: %@", theme.id, error.localizedDescription)
        }
        surface.wake()
    }

    /// Drawn and on screen (the panel up, the body displayed): only then
    /// does the surface hold a target on the shared device.
    func setDrawing(_ drawing: Bool) {
        surface.setActive(drawing)
    }

    /// The representable is going: the surface lets go of its target.
    func teardown() {
        hoverWork?.cancel()
        bench = nil
        surface.teardown()
    }

    // MARK: - Content

    func show(_ document: DiffDocument, wraps: Bool) {
        let sameFiles = document.files.map(\.changed) == self.document.files.map(\.changed)
        self.document = document
        self.wraps = wraps
        if !sameFiles {
            tokens = [:]
            requested = []
            reportedTopFile = nil
        }
        guard let engine else { return }
        engine.setWraps(wraps)
        do {
            // The same files again (a fold) keep the reader's place and every highlight.
            try engine.setFiles(document.files.map(Self.engineFile), truncated: document.truncated,
                                toggled: document.toggled)
        } catch {
            NSLog("pultik: code canvas refused its files: %@", error.localizedDescription)
        }
        surface.wake()
        requestTokens(engine.state)
    }

    /// ⌥Z: the line at the top stays there (Rust keeps it).
    func setWraps(_ wraps: Bool) {
        guard wraps != self.wraps else { return }
        self.wraps = wraps
        engine?.setWraps(wraps)
        surface.wake()
    }

    /// ⌥S: side by side, old on the left; the line at the top stays there.
    /// Side by side has no selection (Rust's is inline only), so ⌘C copies
    /// nothing there.
    func setSplit(_ split: Bool) {
        guard split != self.split else { return }
        self.split = split
        selecting = false
        engine?.setMode(split ? .split : .inline)
        surface.wake()
    }

    /// Runs for one side of one file landed: they draw from the next frame.
    func setTokens(_ runs: LineTokens, file: Int, side: DiffDocument.Side) {
        tokens[file, default: [:]][side] = runs
        guard let engine else { return }
        var flat: [DiffEngine.Run] = []
        var starts: [UInt32] = [0]
        for line in 0 ..< runs.lineCount {
            for run in runs.runs(line: line) {
                flat.append(DiffEngine.Run(start: UInt32(clamping: run.start), length: UInt32(clamping: run.length),
                                           kind: run.kind.rawValue))
            }
            starts.append(UInt32(flat.count))
        }
        do {
            try engine.setTokens(file: file, side: side == .old ? .old : .new, runs: flat, lineStarts: starts)
        } catch {
            NSLog("pultik: code canvas refused file %d's runs: %@", file, error.localizedDescription)
        }
        surface.wake()
    }

    func runs(file: Int, side: DiffDocument.Side) -> LineTokens? {
        tokens[file]?[side]
    }

    private static func engineFile(_ file: DiffDocument.File) -> DiffEngine.File {
        let changed = file.changed
        let status: DiffEngine.Status = switch changed.status {
        case .added: .added
        case .removed: .removed
        case .modified: .modified
        case .renamed: .renamed
        case .copied: .copied
        case .changed: .changed
        case .unchanged: .unchanged
        }
        return DiffEngine.File(path: changed.path, previousPath: changed.previousPath, patch: changed.patch,
                               trimmed: changed.trimmed, status: status, additions: changed.additions,
                               deletions: changed.deletions, hasOldBlob: changed.oldBlob != nil,
                               hasNewBlob: changed.newBlob != nil)
    }

    private func decorate() {
        guard let engine else { return }
        let marks = marks.flatMap { file, lines in lines.map { DiffEngine.Mark(file: file, index: $0) } }
            .sorted { ($0.file, $0.index) < ($1.file, $1.index) }
        do {
            try engine.setDecor(focused: focusedFile, marks: marks, anchor: anchor)
        } catch {
            NSLog("pultik: code canvas refused its decor: %@", error.localizedDescription)
        }
        surface.wake()
    }

    // MARK: - After each frame

    /// The camera may have moved: the tree follows the top file (on the next
    /// turn, never SwiftUI state from the display link) and the files near
    /// the viewport ask for their runs.
    private func viewed() {
        guard let engine else { return }
        let state = engine.state
        if reportedTopFile != .some(state.topFile) {
            reportedTopFile = .some(state.topFile)
            let report = callbacks.topFile
            let file = state.topFile
            DispatchQueue.main.async { report(file) }
        }
        requestTokens(state)
    }

    /// The files from the top edge's to the bottom edge's, and one either
    /// side, that have a language, are unfolded and were not asked for.
    private func requestTokens(_ state: DiffEngine.State) {
        guard !document.files.isEmpty else { return }
        let last = document.files.count - 1
        let top = min(state.topFile ?? 0, last)
        let bottom = min(max(state.bottomFile ?? top, top), last)
        let files = (max(0, top - 1) ... min(last, bottom + 1)).filter { index in
            !requested.contains(index) && document.files[index].language != nil && !document.files[index].collapsed
        }
        guard !files.isEmpty else { return }
        requested.formUnion(files)
        callbacks.needTokens(files)
    }

    // MARK: - Keys (routed by KeyboardCoordinator)

    private var animates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func scroll(_ amount: ScrollAmount) {
        switch amount {
        case let .step(sign): engine?.step(.line, sign: sign, animated: animates)
        case let .page(sign): engine?.step(.page, sign: sign, animated: animates)
        case let .edge(sign): engine?.step(.edge, sign: sign, animated: animates)
        }
        surface.wake()
    }

    /// The file's header at the top — ⇥'s ring and the tree's click.
    func scrollTo(file: Int, animated: Bool = true) {
        guard document.files.indices.contains(file) else { return }
        engine?.reveal(file: file, animated: animated && animates)
        surface.wake()
    }

    /// A new-side line of a file a third of the way down the viewport, its
    /// row washed like a selection; nil = the file's header at the top.
    func scrollTo(file: Int, line: Int?) {
        guard let line, document.files.indices.contains(file), let engine else { return scrollTo(file: file) }
        // Rust brings the header up instead when the diff does not draw the line.
        if let index = engine.reveal(file: file, line: line, animated: animates) { anchor = (file, index ... index) }
        surface.wake()
    }

    var hasSelection: Bool { engine?.state.hasSelection ?? false }

    /// ⌘C: the selected lines' own text, tabs as written. Side by side
    /// selects nothing, so it copies nothing.
    func copySelection() -> Bool {
        guard !split, let text = engine?.selectedText, !text.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    // MARK: - Pointer

    /// Every press is the canvas's: a header folds, a gutter starts a
    /// comment, ⌘ on a word opens its definition, anything else selects.
    private func mouse(_ event: CanvasMouse) -> Bool {
        guard let engine else { return false }
        switch event {
        case let .down(point, flags, _):
            CodeCanvasView.active = self
            selecting = false
            switch engine.hit(x: Double(point.x), y: Double(point.y)) {
            case let .header(file):
                if let path = document.files[safe: file]?.path { callbacks.toggleFile(path) }
                return true
            case let .gutter(file, index):
                callbacks.gutter(file, index, flags.contains(.shift))
                return true
            case .code, .note, .none:
                break
            }
            noteClick(at: point)
            if flags.contains(.command), let word = lastWord {
                callbacks.definition(word)
                return true
            }
            if flags.contains(.shift), engine.state.hasSelection {
                engine.selectExtend(x: Double(point.x), y: Double(point.y))
            } else {
                engine.selectBegin(x: Double(point.x), y: Double(point.y))
            }
            selecting = true
            return true
        case let .dragged(point):
            guard selecting else { return false }
            autoscroll(to: point)
            engine.selectExtend(x: Double(point.x), y: Double(point.y))
            return true
        case .up:
            guard selecting else { return false }
            selecting = false
            // A click without a drag leaves nothing selected.
            if !engine.state.hasSelection { engine.selectClear() }
            return true
        case let .moved(point):
            hover(word(at: point))
            return false
        case .exited:
            hoverWork?.cancel()
            hovered = nil
            callbacks.hover(nil)
            return false
        }
    }

    /// A drag past the top or bottom edge scrolls the diff that far.
    private func autoscroll(to point: NSPoint) {
        let height = surface.bounds.height
        let over = point.y < 0 ? point.y : point.y > height ? point.y - height : 0
        if over != 0 { engine?.scroll(dx: 0, dy: -Double(over)) }
    }

    /// The pointer rests 350 ms on a word before it peeks; moving off it
    /// clears the peek at once.
    private func hover(_ word: CodeWord?) {
        hoverWork?.cancel()
        guard word != hovered else { return }
        guard let word else {
            hovered = nil
            callbacks.hover(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hovered = word
            self?.callbacks.hover(word)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Bench (AC 4) and the panel driver

    /// Scrolls top to bottom at `speed` pt/s on the display link and reports
    /// the frame intervals (p99 ≤ 8.3 ms and none over 16.7 ms on ProMotion)
    /// and the engine's own cost per frame.
    func runScrollBench(speed: CGFloat, done: @escaping ([String: Any]) -> Void) {
        guard let engine, surface.attached, surface.active else {
            return done(["error": "the code canvas is not drawing"])
        }
        engine.step(.edge, sign: -1, animated: false)
        let bench = ScrollBench(engine: engine, speed: Double(speed), lines: lineCount) { [weak self] report in
            self?.bench = nil
            done(report)
        }
        self.bench = bench
        surface.observer = bench
        surface.wake()
    }

    var lineCount: Int { engine?.state.lines ?? 0 }

    /// Files with runs landed on at least one side (the panel driver).
    var highlightedFiles: Int { engine?.state.highlighted ?? 0 }
}

/// `runScrollBench`: before each frame the diff moves by the time since the
/// last one × the speed; after it, the frame's interval and the engine's own
/// cost are kept, until the bottom.
@MainActor
private final class ScrollBench: CanvasFrameObserver {
    private let engine: DiffEngine
    private let speed: Double
    private let lines: Int
    private let done: ([String: Any]) -> Void
    private var last: CFTimeInterval?
    private var step = 0.0
    private var intervals: [Double] = []
    private var costs: [Double] = []

    init(engine: DiffEngine, speed: Double, lines: Int, done: @escaping ([String: Any]) -> Void) {
        self.engine = engine
        self.speed = speed
        self.lines = lines
        self.done = done
    }

    func willDraw(_ view: CanvasView, at timestamp: CFTimeInterval) {
        if let last { intervals.append((timestamp - last) * 1000) }
        step = last.map { (timestamp - $0) * speed } ?? 0
        last = timestamp
        // The content moves up: the view goes toward the end.
        if step > 0 { view.applyScroll(dx: 0, dy: -step) }
    }

    func didDraw(_ view: CanvasView, link: CADisplayLink, cost: Double, built _: Bool) {
        if step > 0 { costs.append(cost) }
        let state = engine.state
        guard state.top >= max(0, state.height - Double(view.bounds.height)) - 0.5 else { return }
        view.observer = nil
        let stats: ([Double]) -> [String: Any] = { values in
            let sorted = values.sorted()
            let pick: (Double) -> Double = { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
            return ["p50": pick(0.5), "p95": pick(0.95), "p99": pick(0.99), "max": sorted.last ?? 0,
                    "over8_3": sorted.filter { $0 > 8.34 }.count, "over16_7": sorted.filter { $0 > 16.7 }.count]
        }
        done(["frames": costs.count, "lines": lines, "speed": speed,
              "refreshMs": (link.targetTimestamp - link.timestamp) * 1000,
              "cost": stats(costs), "interval": stats(intervals)])
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
    /// Side by side (⌥S); a file card stays inline.
    var split = false
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
        view.setSplit(split)
        view.focusedFile = focusedFile
        view.marks = marks
        view.anchor = anchor
        // A warm hidden body or a hidden panel holds no target on the device.
        view.setDrawing(context.environment.panelIsPresented && context.environment.bodyShown)
        if let reveal, reveal.serial != coordinator.revealSerial {
            coordinator.revealSerial = reveal.serial
            // A line waits for the canvas's first size: the next turn has it.
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
        view.teardown()
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
