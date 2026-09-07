import XCTest
@testable import Pultik

final class GitHubResponseCacheTests: XCTestCase {
    func testChangingCommitPathsStayWithinByteBudgetAndKeepRecentlyUsedBody() {
        var cache = GitHubResponseCache(maxBytes: 12, maxEntries: 10)
        cache.insert(.init(etag: "a", data: Data(repeating: 1, count: 6)), for: "sha-a")
        cache.insert(.init(etag: "b", data: Data(repeating: 2, count: 6)), for: "sha-b")
        let inFlight = cache.value(for: "sha-a")
        cache.insert(.init(etag: "c", data: Data(repeating: 3, count: 6)), for: "sha-c")
        XCTAssertNil(cache.value(for: "sha-b"))
        XCTAssertEqual(cache.value(for: "sha-a")?.etag, "a")
        XCTAssertEqual(cache.byteCount, 12)
        for index in 0..<1000 {
            cache.insert(.init(etag: "new", data: Data(repeating: 4, count: 6)), for: "sha-\(index)")
        }
        XCTAssertEqual(cache.count, 2)
        XCTAssertLessThanOrEqual(cache.byteCount, 12)
        XCTAssertNil(cache.value(for: "sha-a"))
        XCTAssertEqual(inFlight?.data, Data(repeating: 1, count: 6),
                       "a request's captured 304 body survives eviction")
    }

    func testEntryLimitAlsoBoundsEmptyResponses() {
        var cache = GitHubResponseCache(maxBytes: 100, maxEntries: 3)
        for index in 0..<1000 {
            cache.insert(.init(etag: "tag", data: Data()), for: "deployment-\(index)")
        }
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertNil(cache.value(for: "deployment-996"))
        XCTAssertNotNil(cache.value(for: "deployment-999"))
    }

    func testReplacementAccountsForBytesAndOversizedBodyDropsOldValidator() {
        var cache = GitHubResponseCache(maxBytes: 10, maxEntries: 3)
        cache.insert(.init(etag: "old", data: Data(count: 8)), for: "runs")
        cache.insert(.init(etag: "new", data: Data(count: 3)), for: "runs")
        XCTAssertEqual(cache.byteCount, 3)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: "runs")?.etag, "new")
        cache.insert(.init(etag: "huge", data: Data(count: 11)), for: "runs")
        XCTAssertEqual(cache.byteCount, 0)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.value(for: "runs"))
    }
}
