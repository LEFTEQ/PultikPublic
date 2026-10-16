import Foundation
import Timeline

// What Semafor's estate hands the Estate and Backups lenses and the estate map
// (vt-7781 WP7, WP8), in the engines' values: each host's `TimelineWindow`
// and live reads, unioned by box — every box from the Semafor that observes
// it (vt-7727 D6), never summed. Words stay Semafor's: one the engine does
// not know is never drawn and never silently dropped — it is counted
// (`unknown`), logged by the feed and named on the page. Pure: the feeds map
// off the main actor, and `tools/test-foundation.sh` tests it.

/// One host's share of an estate lens: its window's events, bins, timers and pins.
struct EstateLensSource: Sendable {
    var host: String
    var events: [EstateTimelineEvent] = []
    var bins: [EstateTimelineBin] = []
    var schedules: [EstateTimelineSchedule] = []
    var pins: [EstateTimelinePin] = []
    /// The bins' width, s; nil: no bins loaded.
    var bucketS: Int?

    init(host: String, events: [EstateTimelineEvent] = [], bins: [EstateTimelineBin] = [],
         schedules: [EstateTimelineSchedule] = [], pins: [EstateTimelinePin] = [], bucketS: Int? = nil)
    {
        (self.host, self.events, self.bins, self.schedules, self.pins, self.bucketS) = (host, events, bins, schedules, pins, bucketS)
    }

    init(host: String, window: TimelineWindow?) {
        self.init(host: host, events: window?.events ?? [], bins: window?.estateBins ?? [],
                  schedules: window?.schedules ?? [], pins: window?.pins ?? [], bucketS: window?.bucketS)
    }

    /// Every box this host's history names.
    var boxes: [String] {
        events.map(\.box) + schedules.map(\.box) + pins.map(\.box) + bins.map(\.box)
    }
}

/// One estate lens's input, as the engine takes it.
struct EstateLensFeed: Sendable, Equatable {
    /// Estate's lanes, one per box, top to bottom (`setBoxes`).
    var boxes: [String] = []
    /// Backups' rows: one stacked group per box, rows keyed `box|surface` (`setGroups`).
    var groups: [TimelineEngine.Group] = []
    var events: [TimelineEngine.Event] = []
    var timers: [TimelineEngine.Timer] = []
    var pins: [TimelineEngine.Pin] = []
    var bins: [TimelineEngine.EstateBin] = []
    /// Semafor words the engine does not know, each with how many items carried it
    /// (`kind 'cert2'`: 3) — those items are not drawn.
    var unknown: [String: Int] = [:]
    /// Finished events that failed or were missed, and rollouts live now (the page's summary).
    var failed = 0
    var live = 0

    var unknownCount: Int { unknown.values.reduce(0, +) }
}

enum EstateLens {
    /// The Backups lens's row of `surface` on `box` (the engine's `backup_row`).
    static func backupRow(box: String, surface: String) -> String { "\(box)|\(surface)" }

    /// D6: each box's host — the Semafor whose live map observes it
    /// (`observed`, `StatusStore.estateBoxes`), else the first host, in
    /// Settings order, whose history names it.
    static func owners(_ sources: [EstateLensSource], observed: [String: String]) -> [String: String] {
        var owner = observed
        for source in sources {
            for box in source.boxes where owner[box] == nil { owner[box] = source.host }
        }
        return owner
    }

    /// `lens`'s input from every host's `sources` (Settings order). `boxOrder`
    /// is the estate's box order (the live map's); `pipelines` are the live
    /// backups (box, surface) the Backups lens draws a row for, as Semafor's
    /// web does, plus any surface the history names that no pipeline lists.
    static func feed(_ lens: TimelineLens, sources: [EstateLensSource], observed: [String: String],
                     boxOrder: [String], pipelines: [(box: String, name: String)] = []) -> EstateLensFeed
    {
        let owner = owners(sources, observed: observed)
        var feed = EstateLensFeed()
        // The rows each box's history names (Backups), in the order first met.
        var surfaces: [String: [String]] = [:]
        func named(_ box: String, _ surface: String) {
            if !(surfaces[box]?.contains(surface) ?? false) { surfaces[box, default: []].append(surface) }
        }
        for source in sources {
            let mine = { (box: String) in owner[box] == source.host }
            for event in source.events where mine(event.box) {
                guard let mapped = Self.event(event, unknown: &feed.unknown) else { continue }
                feed.events.append(mapped)
                if mapped.result == .fail || mapped.result == .missed { feed.failed += 1 }
                if mapped.result == .live { feed.live += 1 }
                named(event.box, event.surface ?? event.title)
            }
            for schedule in source.schedules where mine(schedule.box) {
                guard let mapped = timer(schedule, unknown: &feed.unknown) else { continue }
                feed.timers.append(mapped)
                named(schedule.box, schedule.surface ?? schedule.unit)
            }
            if lens == .estate {
                feed.pins += source.pins.filter { mine($0.box) }.map(pin)
            }
            if let width = source.bucketS {
                for bin in source.bins where mine(bin.box) {
                    guard let mapped = Self.bin(bin, width: TimeInterval(width), unknown: &feed.unknown) else { continue }
                    feed.bins.append(mapped)
                    if let surface = bin.surface { named(bin.box, surface) }
                }
            }
        }
        // Boxes: the estate's order, then the backups' boxes, then any other the history names.
        var order = boxOrder
        for box in pipelines.map(\.box) + owner.keys.sorted() where !order.contains(box) { order.append(box) }
        switch lens {
        case .estate:
            feed.boxes = order
        case .backups:
            feed.groups = order.compactMap { box in
                var rows = pipelines.filter { $0.box == box }.map(\.name).sorted()
                rows += (surfaces[box] ?? []).filter { !rows.contains($0) }.sorted()
                guard !rows.isEmpty else { return nil }
                return TimelineEngine.Group(key: box, label: box, rows: rows.map {
                    TimelineEngine.Row(key: backupRow(box: box, surface: $0), label: $0)
                })
            }
        case .ci:
            break
        }
        return feed
    }

    /// An event in the engine's words; nil (counted in `unknown`) for a kind or result it does not know.
    static func event(_ event: EstateTimelineEvent, unknown: inout [String: Int]) -> TimelineEngine.Event? {
        let kind = TimelineEngine.EventKind(semafor: event.kind)
        let result = TimelineEngine.EventResult(semafor: event.result)
        if kind == nil { unknown["kind '\(event.kind)'", default: 0] += 1 }
        if result == nil { unknown["result '\(event.result)'", default: 0] += 1 }
        guard let kind, let result else { return nil }
        return TimelineEngine.Event(id: event.id, box: event.box, title: event.title, surface: event.surface, kind: kind,
                                    result: result, at: event.at, duration: event.durationS,
                                    sizeBytes: event.sizeBytes.flatMap { $0 >= 0 ? UInt64($0) : nil })
    }

    static func timer(_ schedule: EstateTimelineSchedule, unknown: inout [String: Int]) -> TimelineEngine.Timer? {
        guard let kind = TimelineEngine.EventKind(semafor: schedule.kind) else {
            unknown["timer kind '\(schedule.kind)'", default: 0] += 1
            return nil
        }
        return TimelineEngine.Timer(box: schedule.box, unit: schedule.unit, surface: schedule.surface, kind: kind,
                                    next: schedule.nextAt, period: TimeInterval(schedule.periodS))
    }

    static func pin(_ pin: EstateTimelinePin) -> TimelineEngine.Pin {
        TimelineEngine.Pin(box: pin.box, label: pin.label.isEmpty ? pin.sha : pin.label, from: pin.from, to: pin.to)
    }

    static func bin(_ bin: EstateTimelineBin, width: TimeInterval, unknown: inout [String: Int]) -> TimelineEngine.EstateBin? {
        let row: TimelineEngine.EstateRow? = switch bin.row {
        case "rollouts": .rollouts
        case "backups": .backups
        case "cleanups": .cleanups
        default: nil
        }
        guard let row else {
            unknown["bin row '\(bin.row)'", default: 0] += 1
            return nil
        }
        return TimelineEngine.EstateBin(box: bin.box, surface: bin.surface, row: row, from: bin.from, width: width,
                                        count: UInt32(clamping: bin.count), failures: UInt32(clamping: bin.failures),
                                        scheduled: bin.scheduled)
    }
}

// MARK: - The map (WP8)

/// The estate map's input (`MapEngine.setEstate`) in Semafor's own words.
struct EstateMapInput: Sendable, Equatable {
    var boxes: [MapEngine.Box] = []
    var nodes: [MapEngine.Node] = []
    var edges: [MapEngine.Edge] = []
    /// nil: no host's backups loaded yet.
    var copies: [MapEngine.Copy]?
}

enum EstateMapping {
    /// The copy places the map counts at its storage nodes (`CopyPlace`):
    /// a box's local copy and the restore proof are no store's.
    static let copyPlaces: [BackupPlace] = [.storageBox, .s3, .vault]

    /// `boxes` the estate unioned (D6), the topology of every host (a node or
    /// a link two Semafors both declare is drawn once, from the earlier
    /// host), and the backup copies of `pipelines` (nil: none loaded).
    static func input(boxes: [SemaforEstateMap.Box], topologies: [SemaforEstateTopology],
                      pipelines: [SemaforBackups.Pipeline]?) -> EstateMapInput
    {
        var input = EstateMapInput()
        input.boxes = boxes.map(box)
        var nodeIDs = Set<String>()
        var edgeIDs = Set<String>()
        for topology in topologies {
            for node in topology.nodes where nodeIDs.insert(node.id).inserted {
                input.nodes.append(MapEngine.Node(id: node.id, kind: node.kind, label: node.label,
                                                  detail: node.detail ?? "", place: node.place))
            }
            for edge in topology.edges where edgeIDs.insert(edge.id).inserted {
                input.edges.append(MapEngine.Edge(id: edge.id, from: edge.from, to: edge.to, kind: edge.kind,
                                                  label: edge.label ?? "", both: edge.direction == "both",
                                                  targets: edge.targets))
            }
        }
        input.copies = pipelines.map { pipelines in
            pipelines.flatMap { pipeline in
                copyPlaces.compactMap { place -> MapEngine.Copy? in
                    guard let copy = pipeline.place(place), copy.state != "none" else { return nil }
                    return MapEngine.Copy(box: pipeline.box, pipeline: pipeline.name, place: place.rawValue,
                                          state: copy.state, location: copy.location, age: copy.ageS)
                }
            }
        }
        return input
    }

    /// A live box as the map's frame takes it. A missing sync word crosses
    /// empty, so the engine refuses it by name rather than guessing a state.
    static func box(_ box: SemaforEstateMap.Box) -> MapEngine.Box {
        MapEngine.Box(
            name: box.name, sync: box.sync ?? "", addr: box.addr, line: line(box),
            apps: box.appList.map { MapEngine.App(name: $0.name, sync: $0.sync ?? "", health: $0.health ?? "unknown", note: $0.note) },
            rollouts: (box.liveRollouts ?? []).map { MapEngine.Rollout(gateway: $0.kind == "gateway", target: $0.target, app: $0.app) }
        )
    }

    /// The frame header's second line (Semafor's `FrameHeader`): the pin,
    /// else the live rollout, else the applied commit and its subject.
    static func line(_ box: SemaforEstateMap.Box) -> String? {
        if let pin = box.pin {
            return ["pinned to \(pin.sha ?? "?")", pin.reason].compactMap { $0 }.joined(separator: " · ")
        }
        if let live = box.liveRollouts?.first {
            let title = live.title ?? live.kind ?? "rollout"
            return live.stage.map { "\(title) · \($0)…" } ?? title
        }
        let applied = [box.applied?.sha, subject(box.applied)].compactMap { $0 }.joined(separator: " ")
        return applied.isEmpty ? nil : applied
    }

    /// A commit's subject without the sha Semafor leads it with (`e1e8d39d feat(…)`).
    static func subject(_ commit: SemaforEstateMap.Commit?) -> String? {
        guard let subject = commit?.subject else { return nil }
        let words = subject.split(separator: " ", maxSplits: 1)
        guard let sha = commit?.sha, !sha.isEmpty, words.count == 2, words[0].hasPrefix(sha) else { return subject }
        return String(words[1])
    }
}
