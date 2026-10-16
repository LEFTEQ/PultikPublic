import CTimeline
import Foundation

/// The Estate and Backups lenses' data (`TimelineEngine(lens: .estate | .backups)`): Semafor's
/// estate events, timers, rollback pins and bins. Kinds and results cross as Semafor's words.
extension TimelineEngine {
    public enum EventKind: UInt8, Sendable {
        case reconcile = 0, gateway, eve, backup, restore, cleanup, cert

        public init?(semafor word: String) {
            switch word {
            case "reconcile": self = .reconcile
            case "gateway": self = .gateway
            case "eve": self = .eve
            case "backup": self = .backup
            case "restore": self = .restore
            case "cleanup": self = .cleanup
            case "cert": self = .cert
            default: return nil
            }
        }
    }

    public enum EventResult: UInt8, Sendable {
        case ok = 0, fail, rollback, live, missed, scheduled

        public init?(semafor word: String) {
            switch word {
            case "ok": self = .ok
            case "fail": self = .fail
            case "rollback": self = .rollback
            case "live": self = .live
            case "missed": self = .missed
            case "scheduled": self = .scheduled
            default: return nil
            }
        }
    }

    public enum EstateRow: UInt8, Sendable { case rollouts = 0, backups, cleanups }

    public struct Event: Equatable, Sendable {
        public var id, box, title: String
        public var surface: String?
        public var kind: EventKind
        public var result: EventResult
        public var at: Date
        public var duration: TimeInterval?
        public var sizeBytes: UInt64?

        public init(
            id: String, box: String, title: String, surface: String?, kind: EventKind,
            result: EventResult, at: Date, duration: TimeInterval?, sizeBytes: UInt64?
        ) {
            (self.id, self.box, self.title, self.surface) = (id, box, title, surface)
            (self.kind, self.result, self.at, self.duration, self.sizeBytes) = (kind, result, at, duration, sizeBytes)
        }
    }

    public struct Timer: Equatable, Sendable {
        public var box, unit: String
        public var surface: String?
        public var kind: EventKind
        public var next: Date
        public var period: TimeInterval

        public init(box: String, unit: String, surface: String?, kind: EventKind, next: Date, period: TimeInterval) {
            (self.box, self.unit, self.surface, self.kind, self.next, self.period) = (box, unit, surface, kind, next, period)
        }
    }

    public struct Pin: Equatable, Sendable {
        public var box, label: String
        public var from: Date
        /// nil: still in force.
        public var to: Date?

        public init(box: String, label: String, from: Date, to: Date?) {
            (self.box, self.label, self.from, self.to) = (box, label, from, to)
        }
    }

    public struct EstateBin: Equatable, Sendable {
        public var box: String
        public var surface: String?
        public var row: EstateRow
        public var from: Date
        public var width: TimeInterval
        public var count, failures: UInt32
        public var scheduled: Bool

        public init(
            box: String, surface: String?, row: EstateRow, from: Date, width: TimeInterval,
            count: UInt32, failures: UInt32, scheduled: Bool
        ) {
            (self.box, self.surface, self.row, self.from, self.width) = (box, surface, row, from, width)
            (self.count, self.failures, self.scheduled) = (count, failures, scheduled)
        }
    }

    public func setEvents(_ events: [Event]) throws {
        var arena = TextArena()
        let t = events.map { [arena.add($0.id), arena.add($0.box), arena.add($0.title), arena.add($0.surface ?? "")] }
        try arena.with { base in
            var c = zip(events, t).map { e, t in
                TimelineEstateEvent(
                    id: t[0].at(base), box_name: t[1].at(base), title: t[2].at(base), surface: t[3].at(base),
                    kind: e.kind.rawValue, result: e.result.rawValue, at: e.at.ms,
                    duration: e.duration.map { $0 * 1000 } ?? .nan, size_bytes: e.sizeBytes ?? .max
                )
            }
            try Self.call { timeline_set_estate_events(handle, &c, c.count, $0) }
        }
    }

    public func setTimers(_ timers: [Timer]) throws {
        var arena = TextArena()
        let t = timers.map { [arena.add($0.box), arena.add($0.unit), arena.add($0.surface ?? "")] }
        try arena.with { base in
            var c = zip(timers, t).map { s, t in
                TimelineEstateTimer(
                    box_name: t[0].at(base), unit: t[1].at(base), surface: t[2].at(base),
                    kind: s.kind.rawValue, next: s.next.ms, period: s.period * 1000
                )
            }
            try Self.call { timeline_set_estate_timers(handle, &c, c.count, $0) }
        }
    }

    public func setPins(_ pins: [Pin]) throws {
        var arena = TextArena()
        let t = pins.map { [arena.add($0.box), arena.add($0.label)] }
        try arena.with { base in
            var c = zip(pins, t).map { p, t in
                TimelineEstatePin(box_name: t[0].at(base), label: t[1].at(base), from: p.from.ms, to: p.to?.ms ?? .nan)
            }
            try Self.call { timeline_set_estate_pins(handle, &c, c.count, $0) }
        }
    }

    public func setEstateBins(_ bins: [EstateBin]) throws {
        var arena = TextArena()
        let t = bins.map { [arena.add($0.box), arena.add($0.surface ?? "")] }
        try arena.with { base in
            var c = zip(bins, t).map { b, t in
                TimelineEstateBin(
                    box_name: t[0].at(base), surface: t[1].at(base), row: b.row.rawValue, from: b.from.ms,
                    width: b.width * 1000, count: b.count, failures: b.failures, scheduled: b.scheduled
                )
            }
            try Self.call { timeline_set_estate_bins(handle, &c, c.count, $0) }
        }
    }

    /// The Estate lens's lanes, one per box, top to bottom. (Backups: `setGroups`, rows keyed
    /// `box|surface`.)
    public func setBoxes(_ boxes: [String]) throws {
        var arena = TextArena()
        let t = boxes.map { arena.add($0) }
        try arena.with { base in
            var c = t.map { $0.at(base) }
            try Self.call { timeline_set_estate_boxes(handle, &c, c.count, $0) }
        }
    }
}
