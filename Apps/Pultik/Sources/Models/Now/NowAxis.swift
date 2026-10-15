import Foundation

/// The Now Line's time axis: a rolling 24 h ending now (D12), linear up to a
/// single `//` break, then the last 30 minutes magnified (D13). One
/// monotonic transform for all four lanes — never per-source scaling — and,
/// because the window is fixed, a constant ×N. Positions run 0…1 across the
/// track; views multiply by their width.
struct NowAxis: Equatable, Sendable {
    static let window: TimeInterval = 24 * 3600
    static let magnifiedSpan: TimeInterval = 30 * 60
    /// The ×N chip: how much wider a minute is right of the break.
    static let magnification: Double = 12
    /// The `//` gap's share of the track.
    static let breakShare: Double = 0.02
    /// The linear day's share of the track; the magnified half hour gets the
    /// rest after the break.
    static let linearShare: Double =
        (1 - breakShare) / (1 + magnification * magnifiedSpan / (window - magnifiedSpan))
    static var magnifiedShare: Double { 1 - breakShare - linearShare }

    let now: Date

    var start: Date { now.addingTimeInterval(-Self.window) }
    /// Where the `//` sits: the linear day ends, the magnified half hour begins.
    var breakAt: Date { now.addingTimeInterval(-Self.magnifiedSpan) }

    /// Where an instant draws.
    enum Placement: Equatable, Sendable {
        /// Older than the window: pinned to the left edge with a chevron and
        /// its true age.
        case pinned(age: TimeInterval)
        case track(Double)
        /// After now: a deadline marker in the future gutter, never a bar.
        case future(in: TimeInterval)
    }

    func place(_ date: Date) -> Placement {
        if date < start { return .pinned(age: now.timeIntervalSince(date)) }
        if date > now { return .future(in: date.timeIntervalSince(now)) }
        return .track(x(date))
    }

    /// 0…1 for an instant, clamped to the window.
    func x(_ date: Date) -> Double {
        let clamped = min(max(date, start), now)
        if clamped <= breakAt {
            return Self.linearShare * clamped.timeIntervalSince(start) / (Self.window - Self.magnifiedSpan)
        }
        return Self.linearShare + Self.breakShare
            + Self.magnifiedShare * clamped.timeIntervalSince(breakAt) / Self.magnifiedSpan
    }

    /// An incident's bar: from its onset to now (active bars stop at now).
    struct Bar: Equatable, Sendable {
        let start: Double
        /// The onset predates the window; `age` is the true one.
        let pinned: Bool
        let age: TimeInterval
        /// The onset is a first observation, not the source's instant.
        let hollow: Bool
        let deadline: Placement?
    }

    func bar(_ incident: NowIncident) -> Bar {
        let onset = incident.onset.date
        return Bar(start: x(onset), pinned: onset < start, age: now.timeIntervalSince(onset),
                   hollow: incident.onset.isObserved, deadline: incident.deadline.map(place))
    }
}
