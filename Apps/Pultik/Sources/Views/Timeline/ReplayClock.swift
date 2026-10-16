import Foundation

/// The replay throttle (vt-7781 brief, "replay"): which instant to ask a
/// lens's Semafor for (`/ci/at`, `/estate/map?at=`, `/estate/backups?at=`)
/// while the playhead moves. Moving, the instant is floored to 5 s and at
/// most one request leaves per 120 ms: the newest instant the gap holds back
/// goes once the gap has passed (`flush`, at `flushAt`). On settle the exact
/// instant goes, once. An instant already asked for never goes again, and
/// following now (`follow`) asks for nothing: the live edge is the lens's
/// own read.
///
/// Foundation only, with its clock injected: `Tests/ReplayClockTests.swift`.
final class ReplayClock {
    /// Moving, an instant is floored to this.
    static let step: TimeInterval = 5
    /// At most one request per this, moving or settling.
    static let gap: TimeInterval = 0.12

    private let clock: () -> Date
    /// When the last request left, and the instant it asked for.
    private(set) var sentAt: Date?
    private(set) var asked: Date?
    /// The newest instant the gap holds back.
    private(set) var held: Date?
    /// Requests handed out so far (the panel driver's counter).
    private(set) var requests = 0

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    static func floored(_ instant: Date) -> Date {
        Date(timeIntervalSince1970: (instant.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    /// The playhead moves through `instant`: the floored instant to ask for now, if any.
    func moved(to instant: Date) -> Date? {
        offer(Self.floored(instant))
    }

    /// The playhead came to rest on `instant`: the exact instant to ask for now, if any.
    func settled(on instant: Date) -> Date? {
        offer(instant)
    }

    /// When the held instant may go: the host schedules `flush` for then.
    var flushAt: Date? {
        held == nil ? nil : sentAt.map { $0.addingTimeInterval(Self.gap) }
    }

    /// The held instant, once its gap has passed.
    func flush() -> Date? {
        guard let held, let flushAt, clock() >= flushAt else { return nil }
        return send(held)
    }

    /// The playhead follows now again: nothing stays held, and the next move asks afresh.
    func follow() {
        held = nil
        asked = nil
    }

    private func offer(_ instant: Date) -> Date? {
        if instant == asked {
            held = nil
            return nil
        }
        if let sentAt, clock().timeIntervalSince(sentAt) < Self.gap {
            held = instant
            return nil
        }
        return send(instant)
    }

    private func send(_ instant: Date) -> Date {
        held = nil
        sentAt = clock()
        asked = instant
        requests += 1
        return instant
    }
}
