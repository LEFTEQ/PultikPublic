import Foundation

/// One network request at a time, with foreground work before archive/polling.
/// Search pacing never holds the core queue idle; cancelled waiters are removed.
actor GitHubRequestQueue {
    enum Priority: Int, Sendable { case interactive, background }
    private struct Waiter {
        let id: UUID
        let resource: String
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var active: UUID?
    private var nextRequest = Date.distantPast
    private var nextSearch = Date.distantPast
    private var wake: Task<Void, Never>?
    private let interval: TimeInterval
    private let searchInterval: TimeInterval
    var waitingCount: Int { waiters.count }

    init(interval: TimeInterval = 0.1, searchInterval: TimeInterval = 3) {
        self.interval = interval
        self.searchInterval = searchInterval
    }

    func acquire(id: UUID, resource: String, priority: Priority) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, resource: resource, priority: priority,
                                      continuation: continuation))
                drain()
            }
            // Cancellation can race with admission. Release a granted slot too.
            if Task.isCancelled { release(id: id); throw CancellationError() }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release(id: UUID) {
        guard active == id else { return }
        active = nil
        drain()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }

    private func drain() {
        wake?.cancel()
        wake = nil
        guard active == nil, !waiters.isEmpty else { return }
        let now = Date()
        let ready = waiters.indices.filter {
            max(nextRequest, waiters[$0].resource == "search" ? nextSearch : .distantPast) <= now
        }
        if let index = ready.min(by: { waiters[$0].priority.rawValue < waiters[$1].priority.rawValue }) {
            let waiter = waiters.remove(at: index)
            active = waiter.id
            nextRequest = now.addingTimeInterval(interval)
            if waiter.resource == "search" { nextSearch = now.addingTimeInterval(searchInterval) }
            waiter.continuation.resume()
        } else {
            let earliest = waiters.map {
                max(nextRequest, $0.resource == "search" ? nextSearch : .distantPast)
            }.min() ?? now
            wake = Task {
                do { try await Task.sleep(for: .seconds(max(0, earliest.timeIntervalSinceNow))) }
                catch { return }
                self.drain()
            }
        }
    }
}
