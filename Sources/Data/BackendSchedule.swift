import Foundation
import Observation

/// One independent refresh lane per backend (copilot shell D8), replacing the
/// sequential GitHub → eve → infra → vitrinka → devbox → Sentry pass: a slow
/// GitHub fan-out never holds back vitrinka, and a dead devbox never delays
/// prod. Each lane has exactly one run in flight — a kick while it runs
/// joins that run — and its own interval, measured from its last attempt,
/// so an explicit refresh pushes the next poll back instead of doubling it.
/// Breakers stay where they are: a lane's work still goes through `gated`.
@MainActor
@Observable
final class BackendSchedule {
    struct Lane: Equatable {
        var running = false
        var lastAttempt: Date?
    }

    private(set) var lanes: [String: Lane] = [:]

    /// Fired after every lane run — the app trims memory between polls.
    @ObservationIgnored var onLaneComplete: (() -> Void)?

    private struct Spec {
        let interval: @MainActor () -> TimeInterval
        let work: @MainActor () async -> Void
    }

    @ObservationIgnored private var specs: [String: Spec] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loops: [String: Task<Void, Never>] = [:]

    var isRunning: Bool { lanes.values.contains(where: \.running) }

    func add(_ name: String, every interval: @escaping @MainActor () -> TimeInterval,
             work: @escaping @MainActor () async -> Void) {
        if specs[name] == nil { order.append(name) }
        specs[name] = Spec(interval: interval, work: work)
        if lanes[name] == nil { lanes[name] = Lane() }
    }

    /// Starts every lane's loop; idempotent.
    func start() {
        for name in order where loops[name] == nil {
            loops[name] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let spec = self.specs[name] else { return }
                    let due = (self.lanes[name]?.lastAttempt ?? .distantPast).addingTimeInterval(spec.interval())
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 {
                        // Re-read the interval at least every 15 s: GitHub's
                        // tightens to 30 s the moment a run starts.
                        try? await Task.sleep(for: .seconds(min(wait, 15)))
                        continue
                    }
                    await self.run(name)
                }
            }
        }
    }

    func stop() {
        loops.values.forEach { $0.cancel() }
        loops = [:]
    }

    /// Runs one lane now, or joins its run in flight.
    func run(_ name: String) async {
        if let current = inFlight[name] {
            await current.value
            return
        }
        guard let spec = specs[name] else { return }
        lanes[name, default: Lane()].running = true
        lanes[name]?.lastAttempt = Date()
        let task = Task { @MainActor in await spec.work() }
        inFlight[name] = task
        await task.value
        inFlight[name] = nil
        lanes[name]?.running = false
        onLaneComplete?()
    }

    /// A fresh run after an action: waits out the run in flight (it may have
    /// read before the action landed), then runs the lane once more.
    func rerun(_ name: String) async {
        if let current = inFlight[name] { await current.value }
        await run(name)
    }

    /// Every lane at once — the footer's refresh.
    func runAll() async {
        await withTaskGroup(of: Void.self) { group in
            for name in order {
                group.addTask { await self.run(name) }
            }
        }
    }

    /// Every lane not attempted within `interval` — a panel summon.
    func runStale(olderThan interval: TimeInterval, now: Date = Date()) async {
        let due = order.filter { name in
            guard let last = lanes[name]?.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        await withTaskGroup(of: Void.self) { group in
            for name in due {
                group.addTask { await self.run(name) }
            }
        }
    }
}
