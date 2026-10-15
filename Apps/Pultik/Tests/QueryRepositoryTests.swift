import XCTest
@testable import Pultik

/// AC 5 of the copilot shell: snapshots never cross identities, a relaunch
/// serves the last snapshot with its age, and prod from disk is never green.
@MainActor
final class QueryRepositoryTests: XCTestCase {
    private var directory: URL!
    private let resource = QueryResource<[String]>(name: "test.rows", staleAfter: 60)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pultik-query-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSnapshotWrittenUnderOneIdentityIsNeverServedToAnother() async {
        let store = QuerySnapshotStore(directory: directory)
        let alice = QueryKey(resource: "test.rows", identity: "alice")
        await store.save(["alice's PR"], key: alice, schema: 1, fetchedAt: Date())

        let bob = QueryKey(resource: "test.rows", identity: "bob")
        let forBob = await store.load([String].self, key: bob, schema: 1)
        XCTAssertNil(forBob)
        let forAlice = await store.load([String].self, key: alice, schema: 1)
        XCTAssertEqual(forAlice?.value, ["alice's PR"])
        let otherSchema = await store.load([String].self, key: alice, schema: 2)
        XCTAssertNil(otherSchema)
    }

    func testRelaunchServesTheLastSnapshotWithItsAge() async {
        let key = QueryKey(resource: "test.rows", identity: "alice", scope: "exampleapp")
        let fetchedAt = Date(timeIntervalSince1970: 1_791_472_000)
        QueryRepository(store: QuerySnapshotStore(directory: directory))
            .record(resource, key: key, value: ["#412"], at: fetchedAt)
        try? await Task.sleep(for: .milliseconds(300)) // the write is detached

        // A new process: a fresh store and repository over the same directory.
        let relaunched = QueryRepository(store: QuerySnapshotStore(directory: directory))
        let snapshot = await relaunched.restore(resource, key: key)
        XCTAssertEqual(snapshot?.value, ["#412"])
        XCTAssertEqual(snapshot?.fetchedAt, fetchedAt)
        let freshness = relaunched.freshness["test.rows"]
        XCTAssertEqual(freshness, QueryFreshness(fetchedAt: fetchedAt, restored: true))
        XCTAssertEqual(freshness?.isStale(after: 3600, now: fetchedAt.addingTimeInterval(5)), true,
                       "restored stays stale until a live answer")
    }

    func testProdFromASnapshotReadsAsOfAndIsNeverGreen() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/hlidac-digest.json")
        let digest = try XCTUnwrap(HlidacDigest.decode(Data(contentsOf: url)))
        let utc = TimeZone(identifier: "UTC")!
        let fetchedAt = Date(timeIntervalSince1970: 1_791_472_320) // 15:12 UTC
        let glance = ProdGlance.make(pointers: [], digest: digest, unreachableSince: nil, asOf: fetchedAt,
                                     now: fetchedAt.addingTimeInterval(600), timeZone: utc)
        XCTAssertFalse(glance.cards.isEmpty)
        for card in glance.cards {
            XCTAssertNotEqual(card.tone, .green, card.key)
            XCTAssertFalse(card.emergency, card.key)
            XCTAssertEqual(card.status, "as of 15:12", card.key)
        }
    }

    func testOneFlightPerKeyAndFreshAnswersFromMemory() async throws {
        let repository = QueryRepository(store: QuerySnapshotStore(directory: directory))
        let key = QueryKey(resource: "test.rows", identity: "alice", scope: "pr-412")
        let counter = Counter()
        let fetch: @Sendable () async throws -> [String] = {
            await counter.bump()
            try await Task.sleep(for: .milliseconds(50))
            return ["files"]
        }
        async let first = repository.load(resource, key: key, maxAge: 300, fetch: fetch)
        async let second = repository.load(resource, key: key, maxAge: 300, fetch: fetch)
        let answers = try await [first, second]
        XCTAssertEqual(answers, [["files"], ["files"]])
        _ = try await repository.load(resource, key: key, maxAge: 300, fetch: fetch)
        let calls = await counter.value
        XCTAssertEqual(calls, 1, "the same head reopened issues no second request")
    }

    func testAnImmutableSnapshotIsServedAfterARelaunchWithoutAFetchAndKeepEvictsTheLeastUsed() async throws {
        let files = QueryResource<[String]>(name: "test.files", staleAfter: .infinity, keep: 2)
        func key(_ head: String) -> QueryKey { QueryKey(resource: "test.files", identity: "alice", scope: head) }
        let first = QueryRepository(store: QuerySnapshotStore(directory: directory))
        for head in ["h1", "h2"] {
            _ = try await first.load(files, key: key(head), maxAge: .infinity) { ["diff \(head)"] }
            try await Task.sleep(for: .milliseconds(150)) // the write is detached
        }

        let relaunched = QueryRepository(store: QuerySnapshotStore(directory: directory))
        let counter = Counter()
        let served = try await relaunched.load(files, key: key("h1"), maxAge: .infinity) {
            await counter.bump()
            return ["refetched"]
        }
        XCTAssertEqual(served, ["diff h1"])
        let calls = await counter.value
        XCTAssertEqual(calls, 0, "a relaunch reopens the same head from disk")

        // h1 was last used by that disk read; h2 is used after it from the
        // first process's memory — so a third snapshot evicts h1.
        try await Task.sleep(for: .milliseconds(150))
        _ = try await first.load(files, key: key("h2"), maxAge: .infinity) { ["refetched"] }
        try await Task.sleep(for: .milliseconds(150)) // the touch is detached
        _ = try await relaunched.load(files, key: key("h3"), maxAge: .infinity) { ["diff h3"] }
        try await Task.sleep(for: .milliseconds(150))
        let third = QueryRepository(store: QuerySnapshotStore(directory: directory))
        let kept = try await third.load(files, key: key("h2"), maxAge: .infinity) { ["refetched"] }
        XCTAssertEqual(kept, ["diff h2"], "a memory hit counts as a use on disk")
        let evicted = try await third.load(files, key: key("h1"), maxAge: .infinity) { ["refetched"] }
        XCTAssertEqual(evicted, ["refetched"], "keep: 2 dropped the least recently used snapshot")
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
