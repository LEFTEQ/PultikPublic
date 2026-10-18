import CCanvas
import Foundation
import QuartzCore

/// One diff on screen (D3, D4, docs/specs/2026-10-17-pr-diff-rust-canvas-decisions.md): Swift
/// hands it the change set, each file side's highlight runs as they land, the wrap toggle, the
/// theme and what sits over the code; Rust (`canvas_text::diff_view`) lays it out, scrolls it,
/// hit-tests, selects and draws it, sticky header and scroll indicator included, into the
/// host's `CAMetalLayer` on the shared device. Main-thread only, like the view hosting it.
///
/// The pointer is the host app's: the engine takes every press and hover (`tracksHover`) and
/// hands each to `onMouse`, which answers with the engine's own verbs (`hit`, `selectBegin`,
/// `word(at:)`).
@MainActor
public final class DiffEngine: CanvasEngine {
    /// A file's change, as the host lists it.
    public enum Status: Sendable {
        case added, removed, modified, renamed, copied, changed, unchanged

        var code: UInt8 {
            let code: Int32 = switch self {
            case .added: CANVAS_DIFF_STATUS_ADDED
            case .removed: CANVAS_DIFF_STATUS_REMOVED
            case .modified: CANVAS_DIFF_STATUS_MODIFIED
            case .renamed: CANVAS_DIFF_STATUS_RENAMED
            case .copied: CANVAS_DIFF_STATUS_COPIED
            case .changed: CANVAS_DIFF_STATUS_CHANGED
            case .unchanged: CANVAS_DIFF_STATUS_UNCHANGED
            }
            return UInt8(code)
        }
    }

    /// One file of the change set: what its rows and header need.
    public struct File: Sendable {
        public var path: String
        /// Nil when the file kept its name.
        public var previousPath: String?
        /// Nil for a binary file, one the source would not diff, or one past the patch budget.
        public var patch: String?
        /// The patch was cut at its source's line limit or dropped past its byte budget.
        public var trimmed: Bool
        public var status: Status
        public var additions, deletions: Int
        /// The side's highlights are of its whole blob (its line numbers), not the patch's text.
        public var hasOldBlob, hasNewBlob: Bool

        public init(path: String, previousPath: String?, patch: String?, trimmed: Bool, status: Status,
                    additions: Int, deletions: Int, hasOldBlob: Bool, hasNewBlob: Bool) {
            self.path = path
            self.previousPath = previousPath
            self.patch = patch
            self.trimmed = trimmed
            self.status = status
            self.additions = additions
            self.deletions = deletions
            self.hasOldBlob = hasOldBlob
            self.hasNewBlob = hasNewBlob
        }
    }

    public enum Side: Sendable {
        case old, new

        var code: UInt8 { UInt8(self == .old ? CANVAS_DIFF_SIDE_OLD : CANVAS_DIFF_SIDE_NEW) }
    }

    /// One highlighted run: `start` and `length` in UTF-16 units from its line's start, `kind`
    /// code-core's run kind (0 plain, then each syntax role + 1: `TokenKind.rawValue`).
    public struct Run: Equatable, Sendable {
        public var start, length: UInt32
        public var kind: UInt8

        public init(start: UInt32, length: UInt32, kind: UInt8) {
            (self.start, self.length, self.kind) = (start, length, kind)
        }
    }

    /// A gutter mark: a line (an index into its file's lines) with a pending comment or a thread.
    public struct Mark: Hashable, Sendable {
        public var file, index: Int

        public init(file: Int, index: Int) {
            (self.file, self.index) = (file, index)
        }
    }

    /// Inline, or side by side (old on the left, new on the right). A selection is inline only.
    public enum Mode: Sendable {
        case inline, split

        var code: UInt8 { UInt8(self == .split ? CANVAS_DIFF_MODE_SPLIT : CANVAS_DIFF_MODE_INLINE) }
    }

    /// A key's scroll: three lines, a page (less a little overlap) or to an edge.
    public enum Step: Sendable {
        case line, page, edge

        var code: UInt8 {
            let code: Int32 = switch self {
            case .line: CANVAS_DIFF_STEP_LINE
            case .page: CANVAS_DIFF_STEP_PAGE
            case .edge: CANVAS_DIFF_STEP_EDGE
            }
            return UInt8(code)
        }
    }

    /// What a view point is over. The sticky header is its file's header.
    public enum Hit: Equatable, Sendable {
        case none
        case header(file: Int)
        case gutter(file: Int, index: Int)
        case code(file: Int, index: Int)
        case note(file: Int)
    }

    /// Where the view is: the files at its top and bottom edges, its scroll and height in
    /// points, its rows and drawn lines, and the files with highlights on at least one side.
    public struct State: Equatable, Sendable {
        public let topFile: Int?
        public let bottomFile: Int?
        public let top: Double
        public let height: Double
        public let rows: Int
        public let lines: Int
        public let highlighted: Int
        public let hasSelection: Bool
        public let wraps: Bool
        /// Side by side (`Mode.split`).
        public let split: Bool
    }

    // Freed in the nonisolated deinit; every other use is on the main actor.
    nonisolated(unsafe) let handle: OpaquePointer

    /// The code theme it draws in (a `themes.json` id).
    public private(set) var theme: String
    /// Every press, drag, release and hover over the canvas; true when it changed what is drawn.
    public var onMouse: ((CanvasMouse) -> Bool)?

    /// An empty diff at `fontSize` points in code theme `theme`, with the host's `accent`.
    public init(theme: String, accent: TimelineColor, fontSize: Float = 12) throws {
        var out: OpaquePointer?
        try Self.withText(theme) { id in
            try CanvasError.call(.diff) { canvas_diff_new(id, accent.c, fontSize, &out, $0) }
        }
        guard let out else { throw CanvasError(engine: .diff, kind: .invalid, message: "no diff handle") }
        handle = out
        self.theme = theme
    }

    deinit { canvas_diff_free(handle) }

    // MARK: - Content

    /// The change set, `truncated` when the host stopped listing before the last file, with the
    /// folds of `toggled`'s paths flipped from their default. The same files again (a fold)
    /// keep the reader's place and every highlight.
    public func setFiles(_ files: [File], truncated: Bool, toggled: Set<String>) throws {
        var arena = TextArena()
        let texts = files.map { (arena.add($0.path), arena.add($0.previousPath ?? ""), arena.add($0.patch ?? "")) }
        let flips = toggled.sorted().map { arena.add($0) }
        try arena.with { base in
            let rows = zip(files, texts).map { file, text in
                CanvasDiffFile(path: text.0.at(base), previous_path: text.1.at(base), patch: text.2.at(base),
                               has_patch: file.patch != nil, trimmed: file.trimmed, status: file.status.code,
                               additions: UInt32(clamping: file.additions), deletions: UInt32(clamping: file.deletions),
                               has_old_blob: file.hasOldBlob, has_new_blob: file.hasNewBlob)
            }
            let toggled = flips.map { $0.at(base) }
            try rows.withUnsafeBufferPointer { rows in
                try toggled.withUnsafeBufferPointer { toggled in
                    try CanvasError.call(.diff) {
                        canvas_diff_set_files(handle, rows.baseAddress, rows.count, truncated, toggled.baseAddress,
                                              toggled.count, $0)
                    }
                }
            }
        }
    }

    /// One side of file `file`'s highlights, by source line: line `i`'s runs are
    /// `runs[lineStarts[i] ..< lineStarts[i + 1]]` (code-core's `LineTokens`). Lines the diff
    /// does not draw are dropped.
    public func setTokens(file: Int, side: Side, runs: [Run], lineStarts: [UInt32]) throws {
        let runs = runs.map { CanvasDiffRun(start: $0.start, length: $0.length, kind: $0.kind) }
        try runs.withUnsafeBufferPointer { runs in
            try lineStarts.withUnsafeBufferPointer { starts in
                try CanvasError.call(.diff) {
                    canvas_diff_set_tokens(handle, UInt32(clamping: file), side.code, runs.baseAddress, runs.count,
                                           starts.baseAddress, starts.count, $0)
                }
            }
        }
    }

    /// Wrap long lines under the gutter; the line at the top stays there.
    public func setWraps(_ wraps: Bool) { canvas_diff_set_wraps(handle, wraps) }

    /// Inline or side by side; the line at the top stays there and a selection clears.
    public func setMode(_ mode: Mode) { canvas_diff_set_mode(handle, mode.code) }

    /// Draw in code theme `id` with the host's `accent`: runs are roles, so nothing re-highlights.
    public func setTheme(id: String, accent: TimelineColor) throws {
        try Self.withText(id) { id in
            try CanvasError.call(.diff) { canvas_diff_set_theme(handle, id, accent.c, $0) }
        }
        theme = id
    }

    /// What sits over the code: the ringed file, the gutter marks, and the lines (indices into
    /// `anchor.file`'s lines) a comment is being written about.
    public func setDecor(focused: Int?, marks: [Mark], anchor: (file: Int, lines: ClosedRange<Int>)?) throws {
        let marks = marks.map { CanvasDiffMark(file: UInt32(clamping: $0.file), index: UInt32(clamping: $0.index)) }
        try marks.withUnsafeBufferPointer { marks in
            try CanvasError.call(.diff) {
                canvas_diff_set_decor(handle, Int64(focused ?? -1), marks.baseAddress, marks.count,
                                      Int64(anchor?.file ?? -1), UInt32(clamping: anchor?.lines.lowerBound ?? 0),
                                      UInt32(clamping: anchor?.lines.upperBound ?? 0), $0)
            }
        }
    }

    // MARK: - Scrolling

    /// A key's scroll toward the end (`sign` > 0) or the top, eased unless not `animated`.
    public func step(_ step: Step, sign: Int, animated: Bool) {
        canvas_diff_step(handle, step.code, Int8(clamping: sign.signum()), animated)
    }

    /// File `file`'s header at the top (⇥'s ring, the tree's click).
    public func reveal(file: Int, animated: Bool) {
        canvas_diff_reveal_file(handle, UInt32(clamping: file), animated)
    }

    /// File `file`'s new-side line `line` (1-based) a third of the way down, eased unless not
    /// `animated`; its index in the file's lines, or nil when the diff does not draw it (its
    /// header comes up instead).
    public func reveal(file: Int, line: Int, animated: Bool) -> Int? {
        let index = canvas_diff_reveal_line(handle, UInt32(clamping: file), UInt32(clamping: line), animated)
        return index >= 0 ? Int(index) : nil
    }

    // MARK: - Hits and selection

    public func hit(x: Double, y: Double) -> Hit {
        let hit = canvas_diff_hit(handle, x, y)
        let file = Int(hit.file)
        switch Int32(hit.kind) {
        case CANVAS_DIFF_HIT_HEADER: return .header(file: file)
        case CANVAS_DIFF_HIT_GUTTER: return .gutter(file: file, index: Int(hit.index))
        case CANVAS_DIFF_HIT_CODE: return .code(file: file, index: Int(hit.index))
        case CANVAS_DIFF_HIT_NOTE: return .note(file: file)
        default: return .none
        }
    }

    /// A press at (`x`, `y`) starts a selection there.
    public func selectBegin(x: Double, y: Double) { canvas_diff_select_begin(handle, x, y) }

    /// A drag to (`x`, `y`) moves the selection's head.
    public func selectExtend(x: Double, y: Double) { canvas_diff_select_extend(handle, x, y) }

    public func selectClear() { canvas_diff_select_clear(handle) }

    /// ⌘C: the selected lines' own text, tabs as written; nil with no selection.
    public var selectedText: String? {
        Self.take(canvas_diff_selected_text(handle))
    }

    /// The identifier under (`x`, `y`) and its file: what a hover peeks and ⌘-click follows.
    public func word(at x: Double, y: Double) -> (file: Int, name: String)? {
        var file: UInt32 = 0
        guard let name = Self.take(canvas_diff_word_at(handle, x, y, &file)) else { return nil }
        return (Int(file), name)
    }

    /// The rows in view as text, one per line (the panel driver's reading).
    public var visibleText: String {
        Self.take(canvas_diff_visible_text(handle)) ?? ""
    }

    public var state: State {
        let s = canvas_diff_state(handle)
        return State(topFile: s.top_file >= 0 ? Int(s.top_file) : nil,
                     bottomFile: s.bottom_file >= 0 ? Int(s.bottom_file) : nil, top: s.top, height: s.height,
                     rows: Int(s.rows), lines: Int(s.lines), highlighted: Int(s.highlighted),
                     hasSelection: s.has_selection, wraps: s.wraps, split: s.split)
    }

    // MARK: - CanvasEngine

    public func attach(layer: CAMetalLayer, size: CGSize, scale: CGFloat) throws {
        let raw = Unmanaged.passUnretained(layer).toOpaque()
        try CanvasError.call(.diff) {
            canvas_diff_attach(handle, raw, Double(size.width), Double(size.height), Double(scale), $0)
        }
    }

    public func detach() { canvas_diff_detach(handle) }

    public func resize(size: CGSize, scale: CGFloat) {
        canvas_diff_resize(handle, Double(size.width), Double(size.height), Double(scale))
    }

    public func setNow(_: Date) {}

    /// The content moved by (`dx`, `dy`) points; the diff's own scroll runs the other way
    /// (positive toward the end).
    public func scroll(dx: Double, dy: Double) { canvas_diff_scroll(handle, -dx, -dy) }

    public func magnify(factor _: Double, x _: Double?, y _: Double?) {}

    public func drawFrame() throws -> CanvasFrame {
        var out = CanvasFrameReport(built: false, presented: false, animating: false, next_due_ms: .nan)
        try CanvasError.call(.diff) { canvas_diff_frame(handle, &out, $0) }
        return CanvasFrame(built: out.built, animating: out.animating,
                           nextDue: out.next_due_ms.isFinite ? out.next_due_ms / 1000 : nil)
    }

    /// Never reached: the engine takes every press (`mouse`).
    public func click(x _: Double, y _: Double) throws -> String? { nil }

    public var scrubStrip: CGFloat { 0 }

    public func playhead(x _: Double?, release _: Bool) {}

    public func mouse(_ event: CanvasMouse) -> Bool { onMouse?(event) ?? false }

    public var tracksHover: Bool { true }

    // MARK: - Text

    private static func withText<R>(_ text: String, _ body: (CanvasStr) throws -> R) rethrows -> R {
        var bytes = Array(text.utf8)
        return try bytes.withUnsafeMutableBufferPointer { buffer in
            try body(CanvasStr(ptr: UnsafePointer(buffer.baseAddress), len: buffer.count))
        }
    }

    /// An owned C string as Swift's, freed.
    private static func take(_ raw: UnsafeMutablePointer<CChar>?) -> String? {
        guard let raw else { return nil }
        defer { canvas_string_free(raw) }
        return String(cString: raw)
    }
}
