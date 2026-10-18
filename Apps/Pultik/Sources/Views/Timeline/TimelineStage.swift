import Canvas
import Foundation
import Observation
import QuartzCore

/// A canvas (vt-7727 D1): CI's or Estate's Timeline, Estate's Map, or the
/// Backups timeline above Estate's Pipelines table (vt-7781 WP7).
enum CanvasSlot: String, CaseIterable, Sendable {
    case ciTimeline = "ci.timeline"
    case estateTimeline = "estate.timeline"
    case estateMap = "estate.map"
    case backupsTimeline = "estate.backups"

    init?(module: PanelModule, view: ModuleView?) {
        switch (module, view) {
        case (.ci, .timeline): self = .ciTimeline
        case (.estate, .timeline): self = .estateTimeline
        case (.estate, .map): self = .estateMap
        case (.estate, .backups): self = .backupsTimeline
        default: return nil
        }
    }

    /// The canvas is its view's whole body (`CanvasPage`); Backups' sits in
    /// `BackupsPage`, above its live table.
    var fillsBody: Bool { self != .backupsTimeline }

    /// Its data's lens; nil for the map, which is no timeline.
    var lens: TimelineLens? {
        switch self {
        case .ciTimeline: .ci
        case .estateTimeline: .estate
        case .backupsTimeline: .backups
        case .estateMap: nil
        }
    }

    /// The card of `mark` on this canvas (`DetailRef.Kind.mark`).
    func card(_ mark: String) -> DetailRef {
        DetailRef(kind: .mark, id: "\(rawValue):\(mark)")
    }

    /// The canvas and the mark a card names.
    static func mark(of card: DetailRef) -> (slot: CanvasSlot, mark: String)? {
        guard card.kind == .mark, let colon = card.id.firstIndex(of: ":"),
              let slot = CanvasSlot(rawValue: String(card.id[..<colon])) else { return nil }
        return (slot, String(card.id[card.id.index(after: colon)...]))
    }
}

/// The canvases' engines (vt-7781 WP5, vt-7727 D10): one per canvas view,
/// made when its canvas first mounts and fed from the data Swift holds
/// (`Feed`), so a canvas remounted by ⇥ keeps its camera and selection. The
/// keys reach the shown one through `perform`. The panel's 30 s tree release
/// drops every engine with its GPU device (`release`); the next show makes
/// them again from the feeds.
@MainActor
@Observable
final class TimelineStage {
    static let shared = TimelineStage()

    /// What Swift hands a timeline from Semafor's history (`TimelinePages`):
    /// CI its groups of rows (a row per lane), jobs and bins (WP6); Estate
    /// and Backups their events, timers, pins and bins (`estate`, WP7).
    struct Feed: Sendable {
        var groups: [TimelineEngine.Group] = []
        var jobs: [TimelineEngine.Job] = []
        var bins: [TimelineEngine.Bin] = []
        /// The estate lenses' input; nil on CI.
        var estate: EstateLensFeed?
        /// The card ↵ opens on a mark, by mark id (a job's run: `RunCard`);
        /// a mark without one opens its own `MarkCard`.
        var cards: [String: DetailRef] = [:]
    }

    /// What a canvas wants loaded: its camera's `wanted` range, snapped so a
    /// pan asks again only when it crosses a step, and the bins' width.
    struct Wanted: Equatable {
        var range: ClosedRange<Date>
        var bucket: TimeInterval?
        var span: TimeInterval
    }

    /// What a canvas's header says about its feed: jobs or events, lanes or
    /// rows, the failed and running ones, and the items whose Semafor words
    /// the engine does not know (never drawn, named here).
    struct Summary: Equatable {
        var jobs = 0, lanes = 0, failed = 0, running = 0
        var unknown = 0
        var unknownWords: [String] = []
    }

    private(set) var summaries: [CanvasSlot: Summary] = [:]
    @ObservationIgnored private(set) var feeds: [CanvasSlot: Feed] = [:]
    @ObservationIgnored private var jobIndex: [CanvasSlot: [String: TimelineEngine.Job]] = [:]
    @ObservationIgnored private var timelines: [CanvasSlot: TimelineEngine] = [:]
    /// The estate map (WP8): its own engine, fed `mapInput`.
    @ObservationIgnored private var map: MapEngine?
    @ObservationIgnored private(set) var mapInput: EstateMapInput?
    /// The map's last refusal (an unknown word), shown on its page; nil while it draws.
    private(set) var mapFailure: String?
    @ObservationIgnored private var canvases: [CanvasSlot: WeakCanvas] = [:]
    @ObservationIgnored private var replays: [CanvasSlot: Replay] = [:]
    @ObservationIgnored private var lastWanted: [CanvasSlot: Wanted] = [:]
    /// How a slot's data layer hears its canvas (CI: `CITimelineFeed`).
    struct Hooks {
        /// The canvas started or stopped drawing (its module displayed, the panel up).
        var shown: (Bool) -> Void = { _ in }
        /// The camera wants another range loaded. Called from the display
        /// link, so it must touch no SwiftUI state.
        var wanted: (Wanted) -> Void = { _ in }
        /// A throttled replay instant (vt-7781 brief, "replay"); nil: back to live.
        var replay: (Date?) -> Void = { _ in }
    }

    @ObservationIgnored private var hooks: [CanvasSlot: Hooks] = [:]
    @ObservationIgnored private var shownSlots: Set<CanvasSlot> = []

    /// A slot's data layer listens from now on, told at once whether the
    /// canvas already draws and what it wants (its page can appear after it).
    func install(_ hooks: Hooks, for slot: CanvasSlot) {
        self.hooks[slot] = hooks
        guard shownSlots.contains(slot) else { return }
        hooks.shown(true)
        lastWanted[slot] = nil
        viewed(slot)
    }
    #if DEBUG
    /// Slots the panel driver fed a fixture: live feeds leave them alone until `clear`.
    @ObservationIgnored private(set) var fixtures: Set<CanvasSlot> = []
    #endif

    /// The engine's lens of a timeline slot; nil for the map.
    private static func lens(_ slot: CanvasSlot) -> TimelineEngine.Lens? {
        switch slot.lens {
        case .ci: .ci
        case .estate: .estate
        case .backups: .backups
        case nil: nil
        }
    }

    func engine(for slot: CanvasSlot) -> (any CanvasEngine)? {
        slot == .estateMap ? mapEngine() : timeline(slot)
    }

    private func timeline(_ slot: CanvasSlot) -> TimelineEngine? {
        if let engine = timelines[slot] { return engine }
        guard let lens = Self.lens(slot) else { return nil }
        do {
            let engine = try TimelineEngine(lens: lens, palette: .pultik, now: Date())
            if let feed = feeds[slot] { try apply(feed, to: engine, lens: lens) }
            timelines[slot] = engine
            return engine
        } catch {
            NSLog("pultik: timeline %@ refused: %@", slot.rawValue, error.localizedDescription)
            return nil
        }
    }

    /// Each lens takes its own data: CI lanes and jobs, Estate a lane per box,
    /// Backups a stacked group per box with a row per surface.
    private func apply(_ feed: Feed, to engine: TimelineEngine, lens: TimelineEngine.Lens) throws {
        switch lens {
        case .ci:
            try engine.setGroups(feed.groups)
            try engine.setJobs(feed.jobs)
            try engine.setBins(feed.bins)
        case .estate, .backups:
            let estate = feed.estate ?? EstateLensFeed()
            if lens == .estate {
                try engine.setBoxes(estate.boxes)
                try engine.setPins(estate.pins)
            } else {
                try engine.setGroups(estate.groups)
            }
            try engine.setEvents(estate.events)
            try engine.setTimers(estate.timers)
            try engine.setEstateBins(estate.bins)
        }
    }

    // MARK: - The map (WP8)

    private func mapEngine() -> MapEngine? {
        if let map { return map }
        do {
            let engine = try MapEngine(palette: .pultik)
            if let mapInput { apply(mapInput, to: engine) }
            map = engine
            return engine
        } catch {
            NSLog("pultik: estate map refused: %@", error.localizedDescription)
            return nil
        }
    }

    /// The estate changed (`EstateMapFeed`): the map lays it out again, or —
    /// a word it does not know — refuses it, logged and named on the page.
    func feedMap(_ input: EstateMapInput) {
        guard input != mapInput else { return }
        mapInput = input
        guard let map else { return }
        apply(input, to: map)
        canvas(.estateMap)?.wake()
    }

    private func apply(_ input: EstateMapInput, to engine: MapEngine) {
        do {
            try engine.setEstate(boxes: input.boxes, nodes: input.nodes, edges: input.edges, copies: input.copies)
            if mapFailure != nil { mapFailure = nil }
        } catch {
            let why = error.localizedDescription
            if mapFailure != why { NSLog("pultik: estate map refused its estate: %@", why) }
            mapFailure = why
        }
    }

    /// A key on the entered map: the arrows walk its cards, ⌥←/→ pan a
    /// fifth of it, − / = zoom about its centre, N fits it whole, ↵ answers
    /// the selected card's (an app's, else the node's).
    private func perform(_ move: CanvasMove, on map: MapEngine) -> DetailRef? {
        let size = canvas(.estateMap)?.bounds.size ?? CGSize(width: 800, height: 600)
        switch move {
        case .open:
            if let app = map.selectedApp { return CanvasSlot.estateMap.card("app:\(app.box)/\(app.app)") }
            return map.selected.map { CanvasSlot.estateMap.card($0) }
        case let .node(dx, dy):
            map.walk(dx < 0 ? .left : dx > 0 ? .right : dy < 0 ? .up : .down)
        case let .pan(sign):
            // ⌥→ looks right: the content moves left.
            map.scroll(dx: -Double(sign) * size.width / 5, dy: 0)
        case let .zoom(sign):
            map.magnify(factor: sign < 0 ? 0.8 : 1.25, x: size.width / 2, y: size.height / 2)
        case .now:
            map.fit()
        case .outcome, .mark:
            return nil
        }
        canvas(.estateMap)?.wake()
        return nil
    }

    /// Swift's data for `slot` changed: its engine takes it and its canvas draws it.
    func feed(_ slot: CanvasSlot, _ feed: Feed) {
        #if DEBUG
        guard !fixtures.contains(slot) else { return parked[slot] = feed }
        #endif
        apply(slot, feed)
    }

    #if DEBUG
    /// The live feed a fixture holds back, applied again when it is cleared.
    @ObservationIgnored private var parked: [CanvasSlot: Feed] = [:]

    /// The panel driver's feed (`timeline-demo`, `timeline-bench`): it holds the slot until
    /// `nil` hands it back to the live feed.
    func debugFeed(_ slot: CanvasSlot, _ feed: Feed?) {
        if let feed {
            if !fixtures.contains(slot) { parked[slot] = feeds[slot] }
            fixtures.insert(slot)
            apply(slot, feed)
        } else {
            fixtures.remove(slot)
            apply(slot, parked.removeValue(forKey: slot) ?? Feed())
        }
    }
    #endif

    private func apply(_ slot: CanvasSlot, _ feed: Feed) {
        feeds[slot] = feed
        jobIndex[slot] = Dictionary(feed.jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let summary = if let estate = feed.estate {
            Summary(jobs: estate.events.count,
                    lanes: slot == .estateTimeline ? estate.boxes.count : estate.groups.reduce(0) { $0 + $1.rows.count },
                    failed: estate.failed, running: estate.live, unknown: estate.unknownCount,
                    unknownWords: estate.unknown.keys.sorted())
        } else {
            Summary(jobs: feed.jobs.count, lanes: feed.groups.reduce(0) { $0 + $1.rows.count },
                    failed: feed.jobs.count { $0.result == .failed }, running: feed.jobs.count { $0.result == .running })
        }
        if summaries[slot] != summary { summaries[slot] = summary }
        guard let engine = timelines[slot], let lens = Self.lens(slot) else { return }
        do {
            try apply(feed, to: engine, lens: lens)
        } catch {
            NSLog("pultik: timeline %@ refused its feed: %@", slot.rawValue, error.localizedDescription)
        }
        canvas(slot)?.wake()
    }

    func job(_ slot: CanvasSlot, _ id: String) -> TimelineEngine.Job? {
        jobIndex[slot]?[id]
    }

    // MARK: - Canvases

    func mount(_ canvas: CanvasView, slot: CanvasSlot) {
        canvases[slot] = WeakCanvas(canvas: canvas)
        canvas.use(engine(for: slot))
    }

    func unmount(_ canvas: CanvasView) {
        guard let slot = canvases.first(where: { $0.value.canvas === canvas })?.key else { return }
        canvases[slot] = nil
    }

    func canvas(_ slot: CanvasSlot) -> CanvasView? {
        canvases[slot]?.canvas
    }

    /// `slot`'s canvas started or stopped drawing: its page loads what it wants, or stops.
    func shown(_ slot: CanvasSlot, _ shown: Bool) {
        if shown { shownSlots.insert(slot) } else { shownSlots.remove(slot) }
        lastWanted[slot] = nil
        hooks[slot]?.shown(shown)
        if shown { viewed(slot) }
    }

    /// After a frame: the camera's `wanted` range, snapped to a power-of-two
    /// step of an eighth of the span, so a pan or a pinch asks again a few
    /// times, not once a frame.
    func viewed(_ slot: CanvasSlot) {
        guard let engine = timelines[slot] else { return }
        #if DEBUG
        // A fixture's camera asks the live data layer for nothing.
        if fixtures.contains(slot) { return }
        #endif
        let state = engine.state
        let step = pow(2, (log2(max(state.span / 8, 60))).rounded(.down))
        let lower = (state.wanted.lowerBound.timeIntervalSince1970 / step).rounded(.down) * step
        let upper = (state.wanted.upperBound.timeIntervalSince1970 / step).rounded(.up) * step
        let wanted = Wanted(range: Date(timeIntervalSince1970: lower) ... Date(timeIntervalSince1970: max(lower, upper)),
                            bucket: state.bucket, span: step * 8)
        guard wanted != lastWanted[slot] else { return }
        lastWanted[slot] = wanted
        hooks[slot]?.wanted(wanted)
    }

    /// The panel's tree release (30 s hidden, vt-7727 D10): every engine goes,
    /// then the shared GPU device; the feeds stay for the next show.
    func release() {
        for canvas in canvases.values.compactMap(\.canvas) { canvas.use(nil) }
        for engine in timelines.values { engine.detach() }
        map?.detach()
        map = nil
        timelines = [:]
        canvases = [:]
        for replay in replays.values { replay.cancel() }
        CanvasSurface.release()
    }

    // MARK: - Keys

    /// A key on `slot`'s entered canvas. `.open` changes nothing: it answers
    /// the selected mark's card, which the panel pushes.
    @discardableResult
    func perform(_ move: CanvasMove, on slot: CanvasSlot) -> DetailRef? {
        if slot == .estateMap { return mapEngine().flatMap { perform(move, on: $0) } }
        guard let engine = timeline(slot) else { return nil }
        if move == .open { return engine.selected.map { feeds[slot]?.cards[$0] ?? slot.card($0) } }
        guard let intent = Self.intent(move) else { return nil }
        do {
            try engine.perform(intent)
        } catch {
            NSLog("pultik: timeline %@ refused a key: %@", slot.rawValue, error.localizedDescription)
            return nil
        }
        // A key moves the playhead in one step: it is settled at once.
        replay(slot).moved(engine.state.playhead, settled: true)
        canvas(slot)?.wake()
        return nil
    }

    static func intent(_ move: CanvasMove) -> TimelineEngine.Intent? {
        switch move {
        case let .outcome(sign): sign < 0 ? .outcomeBack : .outcomeForward
        case let .mark(sign): sign < 0 ? .markBack : .markForward
        case let .pan(sign): sign < 0 ? .panBack : .panForward
        case let .zoom(sign): sign < 0 ? .zoomOut : .zoomIn
        case .now: .now
        case .node, .open: nil
        }
    }

    // MARK: - Replay

    /// The playhead moved on `slot`'s canvas: a drag (`settled` on release) or a key.
    func playheadMoved(_ slot: CanvasSlot, settled: Bool) {
        guard let engine = timelines[slot] else { return }
        replay(slot).moved(engine.state.playhead, settled: settled)
    }

    private func replay(_ slot: CanvasSlot) -> Replay {
        if let replay = replays[slot] { return replay }
        let replay = Replay { [weak self] instant in self?.hooks[slot]?.replay(instant) }
        replays[slot] = replay
        return replay
    }

    #if DEBUG
    /// The slots holding an engine (and, while attached, a GPU device).
    var debugEngines: [String] {
        timelines.keys.map(\.rawValue).sorted()
    }

    /// The panel driver's view of a canvas: its engine, device, frames and replay.
    func debugState(_ slot: CanvasSlot) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let summary = summaries[slot] ?? Summary()
        var out: [String: Any] = ["slot": slot.rawValue, "engine": timelines[slot] != nil || (slot == .estateMap && map != nil),
                                  "jobs": summary.jobs, "lanes": summary.lanes, "failed": summary.failed,
                                  "unknown": summary.unknown, "unknownWords": summary.unknownWords]
        if slot == .estateMap {
            out["boxes"] = mapInput?.boxes.count ?? 0
            out["apps"] = mapInput?.boxes.reduce(0) { $0 + $1.apps.count } ?? 0
            out["nodes"] = mapInput?.nodes.count ?? 0
            out["edges"] = mapInput?.edges.count ?? 0
            out["copies"] = mapInput?.copies?.count ?? NSNull()
            out["mapFailure"] = mapFailure ?? NSNull()
            out["selected"] = map?.selected ?? NSNull()
            out["selectedApp"] = map?.selectedApp.map { "\($0.box)/\($0.app)" } ?? NSNull()
        }
        if let canvas = canvas(slot) {
            out["attached"] = canvas.attached
            out["active"] = canvas.active
            out["frames"] = canvas.frames
            out["builds"] = canvas.builds
            out["failure"] = canvas.failure ?? NSNull()
            out["sleeping"] = canvas.sleeping
        }
        out["fixture"] = fixtures.contains(slot)
        out["wanted"] = lastWanted[slot].map { [iso.string(from: $0.range.lowerBound), iso.string(from: $0.range.upperBound)] }
            ?? NSNull()
        if let engine = timelines[slot] {
            let state = engine.state
            out["selected"] = engine.selected ?? NSNull()
            out["t0"] = iso.string(from: state.t0)
            out["spanSeconds"] = state.span
            out["playhead"] = state.playhead.map(iso.string(from:)) ?? NSNull()
            out["bucketSeconds"] = state.bucket ?? NSNull()
        }
        if let replay = replays[slot] {
            out["replayRequests"] = replay.clock.requests
            out["replayLast"] = replay.last.map(iso.string(from:)) ?? NSNull()
        }
        return out
    }

    /// The bench's present mode: Fifo (vsync, the default) or Immediate.
    func debugVSync(_ slot: CanvasSlot, _ on: Bool) {
        timeline(slot)?.setVSync(on)
    }

    /// The canvas's drawable, in pixels (the bench's report).
    func debugDrawableSize(_ slot: CanvasSlot) -> [Double] {
        guard let layer = canvas(slot)?.layer as? CAMetalLayer else { return [] }
        return [Double(layer.drawableSize.width), Double(layer.drawableSize.height)]
    }

    /// Frames `range` on `slot`'s canvas (a fixture's day for the bench).
    func debugZoom(_ slot: CanvasSlot, to range: ClosedRange<Date>) {
        timeline(slot)?.zoom(to: range)
        canvas(slot)?.wake()
    }

    /// What the replay sent since `debugClearReplay` (`timeline-scrub`).
    func debugReplayLog(_ slot: CanvasSlot) -> [(at: Date, instant: Date)] {
        replays[slot]?.sent ?? []
    }

    func debugClearReplay(_ slot: CanvasSlot) {
        replays[slot]?.clearLog()
    }
    #endif
}

private struct WeakCanvas {
    weak var canvas: CanvasView?
}

/// One canvas's replay: the playhead's instants through `ReplayClock`, the
/// held one sent by a timer once its gap has passed.
@MainActor
private final class Replay {
    let clock = ReplayClock()
    private(set) var last: Date?
    private var timer: Timer?
    private let request: (Date?) -> Void

    init(request: @escaping (Date?) -> Void) {
        self.request = request
    }

    /// nil: the playhead follows now again, and the replay goes back to live once.
    func moved(_ instant: Date?, settled: Bool) {
        guard let instant else {
            cancel()
            guard clock.asked != nil else { return }
            clock.follow()
            last = nil
            return request(nil)
        }
        send(settled ? clock.settled(on: instant) : clock.moved(to: instant))
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    #if DEBUG
    /// Every instant handed to the data layer, with when (`timeline-scrub`'s report).
    private(set) var sent: [(at: Date, instant: Date)] = []
    func clearLog() { sent = [] }
    #endif

    private func send(_ instant: Date?) {
        if let instant {
            last = instant
            #if DEBUG
            sent.append((Date(), instant))
            #endif
            request(instant)
        }
        cancel()
        guard let at = clock.flushAt else { return }
        let timer = Timer(timeInterval: max(0, at.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.send(self.clock.flush())
            }
        }
        // A drag's events arrive in the default mode; `.common` keeps the timer firing beside them.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
