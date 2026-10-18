import CCanvas
import Foundation
import QuartzCore

/// One file's merge on screen (vt-7968, `docs/specs/2026-10-18-merge-view-decisions.md`): Swift
/// hands it the merge base, ours and theirs (and, for a past merge, what the commit committed),
/// each pane's highlight runs as they land and the panes' titles; Rust (`code_core::merge`,
/// `canvas_text::merge_view`) merges the file, lays the panes out side by side, scrolls them in
/// step, draws the ribbons between them, walks ⇥ and hit-tests, into the host's `CAMetalLayer`
/// on the shared device. Main-thread only, like the view hosting it.
@MainActor
public final class MergeEngine: CanvasEngine {
    /// A pane, left to right; the merge base shows on demand.
    public enum Pane: Int, CaseIterable, Sendable {
        case base, ours, result, theirs

        var code: UInt8 { UInt8(rawValue) }

        init?(code: UInt8) { self.init(rawValue: Int(code)) }
    }

    /// What a region of the result is.
    public enum Kind: Sendable, Equatable {
        case unchanged, ours, theirs, both, resolved, conflict
    }

    /// How a resolver merged a conflict.
    public enum Resolution: Sendable, Equatable {
        case imports, bothAdded, lines, words, reordered
    }

    /// What a past merge's commit took where it differs from the engine's merge.
    public enum Committed: Sendable, Equatable {
        case ours, theirs, base, hand
    }

    /// One stretch of the merge: its lines (0-based, end-exclusive) in each text.
    public struct Region: Sendable, Equatable {
        public let kind: Kind
        public let resolution: Resolution?
        public let committed: Committed?
        public let base, ours, theirs, result: Range<Int>
    }

    /// What a view point is over.
    public enum Hit: Equatable, Sendable {
        case none
        case header(Pane)
        case line(Pane, line: Int, region: Int?)
        case ribbon(region: Int)
    }

    /// Where the merge is: its regions, conflicts left, resolutions and a past merge's own
    /// decisions, the region ⇥ is on, the scroll and height in points, the panes highlighted.
    public struct State: Equatable, Sendable {
        public let regions: Int
        public let conflicts: Int
        public let resolved: Int
        public let committed: Int
        public let current: Int?
        public let top: Double
        public let height: Double
        public let highlighted: Int
        public let showsBase: Bool
    }

    // Freed in the nonisolated deinit; every other use is on the main actor.
    nonisolated(unsafe) let handle: OpaquePointer

    public private(set) var theme: String
    /// Every press, drag, release and hover over the canvas; true when it changed what is drawn.
    public var onMouse: ((CanvasMouse) -> Bool)?

    /// An empty merge at `fontSize` points in code theme `theme`, with the host's `accent`.
    public init(theme: String, accent: TimelineColor, fontSize: Float = 12) throws {
        var out: OpaquePointer?
        try Self.withText(theme) { id in
            try CanvasError.call(.merge) { canvas_merge_new(id, accent.c, fontSize, &out, $0) }
        }
        guard let out else { throw CanvasError(engine: .merge, kind: .invalid, message: "no merge handle") }
        handle = out
        self.theme = theme
    }

    deinit { canvas_merge_free(handle) }

    // MARK: - Content

    /// One file's merge: `ours` and `theirs` over `base` (the language from `path`); a past
    /// merge passes `committed`, so the result pane is that text and each region says what
    /// the commit took. Highlights, ⇥'s region and the scroll reset.
    public func setFile(path: String, base: String, ours: String, theirs: String, committed: String?) throws {
        var arena = TextArena()
        let texts = [path, base, ours, theirs, committed ?? ""].map { arena.add($0) }
        try arena.with { at in
            try CanvasError.call(.merge) {
                canvas_merge_set_file(handle, texts[0].at(at), texts[1].at(at), texts[2].at(at), texts[3].at(at),
                                      texts[4].at(at), committed != nil, $0)
            }
        }
    }

    /// The panes' titles, by `Pane`: the branches and commits, what the result is.
    public func setLabels(_ labels: [Pane: String]) throws {
        var arena = TextArena()
        let texts = Pane.allCases.map { arena.add(labels[$0] ?? "") }
        try arena.with { at in
            let strs = texts.map { $0.at(at) }
            try strs.withUnsafeBufferPointer { strs in
                try CanvasError.call(.merge) { canvas_merge_set_labels(handle, strs.baseAddress, $0) }
            }
        }
    }

    /// One pane's highlights, by its lines: line `i`'s runs are
    /// `runs[lineStarts[i] ..< lineStarts[i + 1]]` (code-core's `LineTokens`).
    public func setTokens(pane: Pane, runs: [DiffEngine.Run], lineStarts: [UInt32]) throws {
        let runs = runs.map { CanvasDiffRun(start: $0.start, length: $0.length, kind: $0.kind) }
        try runs.withUnsafeBufferPointer { runs in
            try lineStarts.withUnsafeBufferPointer { starts in
                try CanvasError.call(.merge) {
                    canvas_merge_set_tokens(handle, pane.code, runs.baseAddress, runs.count, starts.baseAddress,
                                            starts.count, $0)
                }
            }
        }
    }

    public func setTheme(id: String, accent: TimelineColor) throws {
        try Self.withText(id) { id in
            try CanvasError.call(.merge) { canvas_merge_set_theme(handle, id, accent.c, $0) }
        }
        theme = id
    }

    /// Show the merge base as a fourth pane at the left; the stretch at the centre stays.
    public func setShowsBase(_ shows: Bool) { canvas_merge_set_shows_base(handle, shows) }

    /// The result pane's text (the merged file, or the past merge's commit), to highlight.
    public var result: String { Self.take(canvas_merge_result(handle)) ?? "" }

    /// Every region, in order.
    public var regions: [Region] {
        var out: [Region] = []
        var r = CanvasMergeRegion()
        while canvas_merge_region(handle, UInt32(clamping: out.count), &r) {
            out.append(Self.region(r))
        }
        return out
    }

    /// Why region `index` reads as it does, in Pultík's words.
    public func reason(region index: Int) -> String? {
        Self.take(canvas_merge_region_reason(handle, UInt32(clamping: index)))
    }

    /// One file's merge counted without a view — the conflicts left and the regions resolved —
    /// for a file list. Off the main actor: it merges the whole file.
    public nonisolated static func summary(path: String, base: String, ours: String, theirs: String) throws
        -> (conflicts: Int, resolved: Int) {
        var arena = TextArena()
        let texts = [path, base, ours, theirs].map { arena.add($0) }
        var (conflicts, resolved): (UInt32, UInt32) = (0, 0)
        try arena.with { at in
            try CanvasError.call(.merge) {
                canvas_merge_summary(texts[0].at(at), texts[1].at(at), texts[2].at(at), texts[3].at(at), &conflicts,
                                     &resolved, $0)
            }
        }
        return (Int(conflicts), Int(resolved))
    }

    // MARK: - Scrolling and ⇥

    /// A key's scroll toward the end (`sign` > 0) or the top, eased unless not `animated`.
    public func step(_ step: DiffEngine.Step, sign: Int, animated: Bool) {
        canvas_merge_step(handle, step.code, Int8(clamping: sign.signum()), animated)
    }

    /// ⇥ (`forward`) or ⇧⇥: the next conflict or resolution, wrapping, revealed a third of the
    /// way down; nil when the merge has none.
    @discardableResult
    public func next(forward: Bool, animated: Bool) -> Int? {
        let k = canvas_merge_next(handle, forward, animated)
        return k >= 0 ? Int(k) : nil
    }

    /// Region `region` becomes ⇥'s (nil: none), revealed when `reveal`.
    public func select(region: Int?, reveal: Bool, animated: Bool) {
        canvas_merge_select(handle, Int64(region ?? -1), reveal, animated)
    }

    public func hit(x: Double, y: Double) -> Hit {
        let h = canvas_merge_hit(handle, x, y)
        let region = h.region >= 0 ? Int(h.region) : nil
        switch Int32(h.kind) {
        case CANVAS_MERGE_HIT_HEADER: return Pane(code: h.pane).map(Hit.header) ?? .none
        case CANVAS_MERGE_HIT_LINE:
            return Pane(code: h.pane).map { .line($0, line: Int(h.line), region: region) } ?? .none
        case CANVAS_MERGE_HIT_RIBBON: return region.map { .ribbon(region: $0) } ?? .none
        default: return .none
        }
    }

    /// Each shown pane's title and lines in view (the panel driver's reading).
    public var visibleText: String { Self.take(canvas_merge_visible_text(handle)) ?? "" }

    public var state: State {
        let s = canvas_merge_state(handle)
        return State(regions: Int(s.regions), conflicts: Int(s.conflicts), resolved: Int(s.resolved),
                     committed: Int(s.committed), current: s.current >= 0 ? Int(s.current) : nil, top: s.top,
                     height: s.height, highlighted: Int(s.highlighted), showsBase: s.shows_base)
    }

    // MARK: - CanvasEngine

    public func attach(layer: CAMetalLayer, size: CGSize, scale: CGFloat) throws {
        let raw = Unmanaged.passUnretained(layer).toOpaque()
        try CanvasError.call(.merge) {
            canvas_merge_attach(handle, raw, Double(size.width), Double(size.height), Double(scale), $0)
        }
    }

    public func detach() { canvas_merge_detach(handle) }

    public func resize(size: CGSize, scale: CGFloat) {
        canvas_merge_resize(handle, Double(size.width), Double(size.height), Double(scale))
    }

    public func setNow(_: Date) {}

    /// The content moved by (`dx`, `dy`) points; the merge's own scroll runs the other way.
    public func scroll(dx: Double, dy: Double) { canvas_merge_scroll(handle, -dx, -dy) }

    public func magnify(factor _: Double, x _: Double?, y _: Double?) {}

    public func drawFrame() throws -> CanvasFrame {
        var out = CanvasFrameReport(built: false, presented: false, animating: false, next_due_ms: .nan)
        try CanvasError.call(.merge) { canvas_merge_frame(handle, &out, $0) }
        return CanvasFrame(built: out.built, animating: out.animating,
                           nextDue: out.next_due_ms.isFinite ? out.next_due_ms / 1000 : nil)
    }

    /// Never reached: the engine takes every press (`mouse`).
    public func click(x _: Double, y _: Double) throws -> String? { nil }

    public var scrubStrip: CGFloat { 0 }

    public func playhead(x _: Double?, release _: Bool) {}

    public func mouse(_ event: CanvasMouse) -> Bool { onMouse?(event) ?? false }

    public var tracksHover: Bool { false }

    // MARK: - C values

    private static func region(_ r: CanvasMergeRegion) -> Region {
        let kind: Kind = switch Int32(r.kind) {
        case CANVAS_MERGE_REGION_OURS: .ours
        case CANVAS_MERGE_REGION_THEIRS: .theirs
        case CANVAS_MERGE_REGION_BOTH: .both
        case CANVAS_MERGE_REGION_RESOLVED: .resolved
        case CANVAS_MERGE_REGION_CONFLICT: .conflict
        default: .unchanged
        }
        let resolution: Resolution? = switch Int32(r.resolution) {
        case CANVAS_MERGE_RESOLUTION_IMPORTS: .imports
        case CANVAS_MERGE_RESOLUTION_BOTH_ADDED: .bothAdded
        case CANVAS_MERGE_RESOLUTION_LINES: .lines
        case CANVAS_MERGE_RESOLUTION_WORDS: .words
        case CANVAS_MERGE_RESOLUTION_REORDERED: .reordered
        default: nil
        }
        let committed: Committed? = switch Int32(r.committed) {
        case CANVAS_MERGE_COMMITTED_OURS: .ours
        case CANVAS_MERGE_COMMITTED_THEIRS: .theirs
        case CANVAS_MERGE_COMMITTED_BASE: .base
        case CANVAS_MERGE_COMMITTED_HAND: .hand
        default: nil
        }
        let range = { (a: UInt32, b: UInt32) in Int(a) ..< Int(max(a, b)) }
        return Region(kind: kind, resolution: resolution, committed: committed,
                      base: range(r.base_start, r.base_end), ours: range(r.ours_start, r.ours_end),
                      theirs: range(r.theirs_start, r.theirs_end), result: range(r.result_start, r.result_end))
    }

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
