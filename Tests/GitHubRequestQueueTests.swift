import XCTest
@testable import Pultik

final class GitHubRequestQueueTests: XCTestCase {
    private actor Order {
        var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    func testForegroundPassesQueuedBackgroundAndCancelledWaitersDisappear() async throws {
        let queue = GitHubRequestQueue(interval: 0, searchInterval: 0)
        let order = Order()
        let held = UUID()
        try await queue.acquire(id: held, resource: "core", priority: .background)
        let background = Task {
            let id = UUID()
            try await queue.acquire(id: id, resource: "core", priority: .background)
            await order.append("background")
            await queue.release(id: id)
        }
        let cancelled = Task {
            try await queue.acquire(id: UUID(), resource: "core", priority: .interactive)
        }
        let foreground = Task {
            let id = UUID()
            try await queue.acquire(id: id, resource: "core", priority: .interactive)
            await order.append("foreground")
            await queue.release(id: id)
        }
        for _ in 0..<10_000 {
            if await queue.waitingCount == 3 { break }
            await Task.yield()
        }
        let count = await queue.waitingCount
        XCTAssertEqual(count, 3)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("cancelled waiter acquired a slot") }
        catch is CancellationError {} // expected
        await queue.release(id: held)
        try await foreground.value
        try await background.value
        let values = await order.values
        XCTAssertEqual(values, ["foreground", "background"])
    }

    func testSearchPacingDoesNotBlockAReadyCoreRequest() async throws {
        let queue = GitHubRequestQueue(interval: 0, searchInterval: 0.2)
        let first = UUID()
        try await queue.acquire(id: first, resource: "search", priority: .interactive)
        await queue.release(id: first)
        let order = Order()
        async let search: Void = request(queue, resource: "search", order: order)
        async let core: Void = request(queue, resource: "core", order: order)
        try await search
        try await core
        let values = await order.values
        XCTAssertEqual(values, ["core", "search"])
    }

    private func request(_ queue: GitHubRequestQueue, resource: String, order: Order) async throws {
        let id = UUID()
        try await queue.acquire(id: id, resource: resource, priority: .interactive)
        await order.append(resource)
        await queue.release(id: id)
    }
}
