import CCanvas
import Foundation
import QuartzCore

/// A straight-alpha sRGB colour in `0...1`.
public struct TimelineColor: Equatable, Sendable {
    public var red, green, blue, alpha: Float

    public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    var c: CanvasRgba { CanvasRgba(r: red, g: green, b: blue, a: alpha) }
}

/// One timeline on screen: the data Swift loaded, its gestures and keys in; Rust lays it out,
/// hit-tests, steps, moves its camera and draws it into the host's `CAMetalLayer`.
/// Main-thread only, like the view hosting it.
@MainActor
public final class TimelineEngine {
    public enum Lens: UInt8, Sendable { case ci = 0, estate, backups }

    /// The axis strip's height and the label column's width, points.
    public static let axisHeight = CGFloat(CANVAS_TIMELINE_AXIS_PT)
    public static let labelWidth = CGFloat(CANVAS_TIMELINE_LABEL_W)

    /// The host's status tokens: colour means status (D4), never a repository.
    public struct Palette: Equatable, Sendable {
        public var background, band, foreground, muted, grid, data, ok, danger, warning, accent: TimelineColor

        public init(
            background: TimelineColor, band: TimelineColor, foreground: TimelineColor,
            muted: TimelineColor, grid: TimelineColor, data: TimelineColor, ok: TimelineColor,
            danger: TimelineColor, warning: TimelineColor, accent: TimelineColor
        ) {
            (self.background, self.band, self.foreground, self.muted, self.grid) = (background, band, foreground, muted, grid)
            (self.data, self.ok, self.danger, self.warning, self.accent) = (data, ok, danger, warning, accent)
        }

        var c: CanvasTimelinePalette {
            CanvasTimelinePalette(
                background: background.c, band: band.c, foreground: foreground.c, muted: muted.c,
                grid: grid.c, data: data.c, ok: ok.c, danger: danger.c, warning: warning.c,
                accent: accent.c
            )
        }
    }

    public enum JobResult: UInt8, Sendable {
        case succeeded = 0, failed, cancelled, unknown, running, waiting
    }

    /// One CI job as Semafor lists it.
    public struct Job: Equatable, Sendable {
        public var id, lane, repo, name: String
        public var queuedAt: Date
        public var startedAt, completedAt: Date?
        public var result: JobResult
        public var peakMiB, reservedMiB: UInt32?

        public init(
            id: String, lane: String, repo: String, name: String, queuedAt: Date,
            startedAt: Date?, completedAt: Date?, result: JobResult,
            peakMiB: UInt32? = nil, reservedMiB: UInt32? = nil
        ) {
            (self.id, self.lane, self.repo, self.name) = (id, lane, repo, name)
            (self.queuedAt, self.startedAt, self.completedAt) = (queuedAt, startedAt, completedAt)
            (self.result, self.peakMiB, self.reservedMiB) = (result, peakMiB, reservedMiB)
        }
    }

    /// `count` items on `row` in `[from, from + width)`, `failures` of them failed.
    public struct Bin: Equatable, Sendable {
        public var row: String
        public var from: Date
        public var width: TimeInterval
        public var count, failures: UInt32

        public init(row: String, from: Date, width: TimeInterval, count: UInt32, failures: UInt32) {
            (self.row, self.from, self.width, self.count, self.failures) = (row, from, width, count, failures)
        }
    }

    public struct Row: Equatable, Sendable {
        public var key, label: String
        /// The lane glyph's identity tint (a repository), if any.
        public var tint: TimelineColor?

        public init(key: String, label: String, tint: TimelineColor? = nil) {
            (self.key, self.label, self.tint) = (key, label, tint)
        }
    }

    public struct Group: Equatable, Sendable {
        public var key, label: String
        public var rows: [Row]

        public init(key: String, label: String, rows: [Row]) {
            (self.key, self.label, self.rows) = (key, label, rows)
        }
    }

    /// A key's intent in an entered timeline (D5).
    public enum Intent: UInt8, Sendable {
        case outcomeBack = 0, outcomeForward, markBack, markForward, panBack, panForward
        case zoomOut, zoomIn, now
    }

    public struct Frame: Equatable, Sendable {
        /// The scene was built again (a level, the window, the data or the selection changed).
        public let built: Bool
        public let presented: Bool
        /// Keep the display link running: something moves every frame (a flowing dash).
        public let animating: Bool
        /// How long until a frame is due without input (a running job grows): sleep that long
        /// instead of ticking. nil: nothing is due.
        public let nextDue: TimeInterval?
    }

    public struct State: Equatable, Sendable {
        public let t0: Date
        public let span: TimeInterval
        /// What to load: the visible span plus one either side.
        public let wanted: ClosedRange<Date>
        /// The bin width to ask for; nil while marks are enough.
        public let bucket: TimeInterval?
        /// The replay instant; nil while it follows now.
        public let playhead: Date?
    }

    public enum Hit: Equatable, Sendable {
        case none
        case mark(id: String)
        case cluster(from: Date, to: Date)
        case rail(from: Date)
        case band(key: String, from: Date, to: Date?)
    }

    // Freed in the nonisolated deinit; every other use is on the main actor.
    nonisolated(unsafe) let handle: OpaquePointer

    public init(lens: Lens, palette: Palette, now: Date) throws {
        var palette = palette.c
        var out: OpaquePointer?
        try CanvasError.call(.timeline) { canvas_timeline_new(lens.rawValue, &palette, now.ms, &out, $0) }
        guard let out else { throw CanvasError(engine: .timeline, kind: .invalid, message: "no handle") }
        handle = out
    }

    deinit { canvas_timeline_free(handle) }

    /// Draw into `layer`: creates the GPU device (the first show).
    public func attach(layer: CAMetalLayer, size: CGSize, scale: CGFloat) throws {
        let raw = Unmanaged.passUnretained(layer).toOpaque()
        try CanvasError.call(.timeline) {
            canvas_timeline_attach(handle, raw, Double(size.width), Double(size.height), Double(scale), $0)
        }
    }

    /// Release the GPU device (the panel's tree release); the data stays.
    public func detach() { canvas_timeline_detach(handle) }

    /// Present in step with the display (the default) or as soon as a frame is done.
    public func setVSync(_ vsync: Bool) { canvas_timeline_set_vsync(handle, vsync) }

    public func resize(size: CGSize, scale: CGFloat) throws {
        try CanvasError.call(.timeline) {
            canvas_timeline_resize(handle, Double(size.width), Double(size.height), Double(scale), $0)
        }
    }

    public func setNow(_ now: Date) { canvas_timeline_set_now(handle, now.ms) }

    public func setPalette(_ palette: Palette) {
        var palette = palette.c
        canvas_timeline_set_palette(handle, &palette)
    }

    public func setJobs(_ jobs: [Job]) throws {
        var arena = TextArena()
        let texts = jobs.map { j in [arena.add(j.id), arena.add(j.lane), arena.add(j.repo), arena.add(j.name)] }
        try arena.with { base in
            var c = zip(jobs, texts).map { j, t in
                CanvasTimelineCiJob(
                    id: t[0].at(base), lane: t[1].at(base), repo: t[2].at(base), name: t[3].at(base),
                    queued_at: j.queuedAt.ms, started_at: j.startedAt?.ms ?? .nan,
                    completed_at: j.completedAt?.ms ?? .nan, result: j.result.rawValue,
                    peak_mib: j.peakMiB ?? .max, reserved_mib: j.reservedMiB ?? .max
                )
            }
            try CanvasError.call(.timeline) { canvas_timeline_set_ci_jobs(handle, &c, c.count, $0) }
        }
    }

    public func setBins(_ bins: [Bin]) throws {
        var arena = TextArena()
        let rows = bins.map { arena.add($0.row) }
        try arena.with { base in
            var c = zip(bins, rows).map { b, r in
                CanvasTimelineBin(row: r.at(base), from: b.from.ms, width: b.width * 1000, count: b.count, failures: b.failures)
            }
            try CanvasError.call(.timeline) { canvas_timeline_set_bins(handle, &c, c.count, $0) }
        }
    }

    public func setGroups(_ groups: [Group]) throws {
        var arena = TextArena()
        let keys = groups.map { g in (arena.add(g.key), arena.add(g.label), g.rows.map { (arena.add($0.key), arena.add($0.label)) }) }
        try arena.with { base in
            // Every group's rows in one array; each group points at its run of it.
            let clear = TimelineColor(red: 0, green: 0, blue: 0, alpha: 0)
            let rows = zip(groups, keys).flatMap { g, k in
                zip(g.rows, k.2).map { r, t in
                    CanvasTimelineRow(key: t.0.at(base), label: t.1.at(base), tint: (r.tint ?? clear).c, has_tint: r.tint != nil)
                }
            }
            try rows.withUnsafeBufferPointer { all in
                var start = 0
                var c: [CanvasTimelineGroup] = []
                for (g, k) in zip(groups, keys) {
                    let first = all.baseAddress.map { $0 + start }
                    c.append(CanvasTimelineGroup(key: k.0.at(base), label: k.1.at(base), rows: g.rows.isEmpty ? nil : first, row_count: g.rows.count))
                    start += g.rows.count
                }
                try CanvasError.call(.timeline) { canvas_timeline_set_groups(handle, &c, c.count, $0) }
            }
        }
    }

    /// Show `range` across a quarter of the lanes (a cluster or a band opened by a click).
    public func zoom(to range: ClosedRange<Date>) {
        canvas_timeline_zoom_to(handle, range.lowerBound.ms, range.upperBound.ms)
    }

    /// Two fingers moved the content by (`dx`, `dy`) points.
    public func scroll(dx: Double, dy: Double) { canvas_timeline_scroll(handle, dx, dy) }

    /// A pinch by `factor` around view point `x` (nil: the lanes' centre).
    public func magnify(factor: Double, x: Double?) { canvas_timeline_magnify(handle, factor, x ?? .nan) }

    public func perform(_ intent: Intent) throws {
        try CanvasError.call(.timeline) { canvas_timeline_key(handle, intent.rawValue, $0) }
    }

    public func select(_ id: String?) throws {
        let text = id ?? ""
        var bytes = Array(text.utf8)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            let s = CanvasStr(ptr: UnsafePointer(buffer.baseAddress), len: buffer.count)
            try CanvasError.call(.timeline) { canvas_timeline_select(handle, s, $0) }
        }
    }

    public var selected: String? {
        guard let raw = canvas_timeline_selected(handle) else { return nil }
        defer { canvas_string_free(raw) }
        return String(cString: raw)
    }

    /// The playhead dragged to view point `x` (nil: back to now); `release` snaps it.
    public func playhead(x: Double?, release: Bool) {
        canvas_timeline_playhead(handle, x ?? .nan, release)
    }

    public func hit(x: Double, y: Double) throws -> Hit {
        var out = CanvasTimelineHit(kind: 0, id: nil, from: .nan, to: .nan)
        try CanvasError.call(.timeline) { canvas_timeline_hit(handle, x, y, &out, $0) }
        defer { canvas_string_free(out.id) }
        let id = out.id.map { String(cString: $0) }
        switch Int32(out.kind) {
        case CANVAS_TIMELINE_HIT_MARK: return id.map { .mark(id: $0) } ?? .none
        case CANVAS_TIMELINE_HIT_CLUSTER: return .cluster(from: Date(ms: out.from), to: Date(ms: out.to))
        case CANVAS_TIMELINE_HIT_RAIL: return .rail(from: Date(ms: out.from))
        case CANVAS_TIMELINE_HIT_BAND:
            return .band(key: id ?? "", from: Date(ms: out.from), to: out.to.isFinite ? Date(ms: out.to) : nil)
        default: return .none
        }
    }

    public var state: State {
        let s = canvas_timeline_state(handle)
        return State(
            t0: Date(ms: s.t0), span: s.span / 1000,
            wanted: Date(ms: s.wanted_from)...Date(ms: max(s.wanted_from, s.wanted_to)),
            bucket: s.bucket.isFinite ? s.bucket / 1000 : nil,
            playhead: s.playhead.isFinite ? Date(ms: s.playhead) : nil
        )
    }

    /// Draw a frame if anything changed; call it from the display link while `animating`.
    public func frame() throws -> Frame {
        var out = CanvasFrameReport(built: false, presented: false, animating: false, next_due_ms: .nan)
        try CanvasError.call(.timeline) { canvas_timeline_frame(handle, &out, $0) }
        return Frame(
            built: out.built, presented: out.presented, animating: out.animating,
            nextDue: out.next_due_ms.isFinite ? out.next_due_ms / 1000 : nil
        )
    }
}

/// Every text of one call in one buffer, so the C structs point into memory alive for the call.
struct TextArena {
    struct Slice {
        let offset, count: Int
        func at(_ base: UnsafePointer<UInt8>?) -> CanvasStr {
            CanvasStr(ptr: count > 0 ? base.map { $0 + offset } : nil, len: count)
        }
    }

    private var bytes: [UInt8] = []

    mutating func add(_ s: String) -> Slice {
        let offset = bytes.count
        bytes.append(contentsOf: s.utf8)
        return Slice(offset: offset, count: bytes.count - offset)
    }

    func with<R>(_ body: (UnsafePointer<UInt8>?) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { try body($0.baseAddress) }
    }
}

extension Date {
    /// Milliseconds since the Unix epoch, the engine's unit.
    var ms: Double { timeIntervalSince1970 * 1000 }

    init(ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}
