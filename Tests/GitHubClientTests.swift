import XCTest
@testable import Pultik

/// Requests use an ephemeral fixture transport: no GitHub credentials or API calls.
final class GitHubClientTests: XCTestCase {
    private func client() -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubFixtureProtocol.self]
        return GitHubClient(session: URLSession(configuration: config),
            queue: GitHubRequestQueue(interval: 0, searchInterval: 0), tokenProvider: { "test-identity" })
    }

    func testIdenticalNumberLookupsShareOneRequestAndOneCallerCanCancel() async throws {
        GitHubFixtureProtocol.fixture.reset(status: 200)
        let client = client()
        let first = Task { try await client.lookupPullRequests(number: 1744, repos: ["owner/a"]) }
        for _ in 0..<10_000 {
            if GitHubFixtureProtocol.fixture.count > 0 { break }
            await Task.yield()
        }
        let second = Task { try await client.lookupPullRequests(number: 1744, repos: ["owner/a"]) }
        for _ in 0..<10_000 {
            if await client.sharedRequests > 0 { break }
            await Task.yield()
        }
        let shared = await client.sharedRequests
        XCTAssertEqual(shared, 1)
        first.cancel()
        let answer = try await second.value
        do { _ = try await first.value; XCTFail("cancelled caller returned rows") }
        catch is CancellationError {} // expected; the other subscriber survives
        XCTAssertEqual(answer.hits.first?.number, 1744)
        XCTAssertEqual(answer.confirmedRepos, ["owner/a"])
        XCTAssertEqual(GitHubFixtureProtocol.fixture.count, 1)
    }

    func testRateLimitStopsNumberSweepWithoutConfirmingAnyAbsence() async throws {
        GitHubFixtureProtocol.fixture.reset(status: 429)
        let client = client()
        let answer = try await client.lookupPullRequests(number: 1744, repos: ["owner/a", "owner/b", "owner/c"])
        XCTAssertTrue(answer.confirmedRepos.isEmpty)
        XCTAssertNotNil(answer.warning)
        XCTAssertEqual(GitHubFixtureProtocol.fixture.count, 1)
        _ = try await client.lookupPullRequests(number: 1745, repos: ["owner/a", "owner/b"])
        XCTAssertEqual(GitHubFixtureProtocol.fixture.count, 1, "known deadline blocks the next sweep too")
    }

    func testCancellingTheLastSubscriberRemovesQueuedNetworkWork() async throws {
        GitHubFixtureProtocol.fixture.reset(status: 200)
        let queue = GitHubRequestQueue(interval: 0, searchInterval: 0)
        let held = UUID()
        try await queue.acquire(id: held, resource: "core", priority: .background)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubFixtureProtocol.self]
        let client = GitHubClient(session: URLSession(configuration: config), queue: queue,
                                  tokenProvider: { "test-identity" })
        let lookup = Task { try await client.lookupPullRequests(number: 1744, repos: ["owner/a"]) }
        for _ in 0..<10_000 {
            if await queue.waitingCount == 1 { break }
            await Task.yield()
        }
        lookup.cancel()
        do { _ = try await lookup.value; XCTFail("cancelled lookup returned") }
        catch is CancellationError {} // expected
        await queue.release(id: held)
        XCTAssertEqual(GitHubFixtureProtocol.fixture.count, 0)
    }

    func testOnlyNotFoundConfirmsANumberMiss() async throws {
        GitHubFixtureProtocol.fixture.reset(status: 404)
        let missing = try await client().lookupPullRequests(number: 1744, repos: ["owner/a"])
        XCTAssertEqual(missing.confirmedRepos, ["owner/a"])
        XCTAssertNil(missing.warning)
        GitHubFixtureProtocol.fixture.reset(status: 403)
        let denied = try await client().lookupPullRequests(number: 1744, repos: ["owner/a"])
        XCTAssertTrue(denied.confirmedRepos.isEmpty)
        XCTAssertNotNil(denied.warning)
    }

    func testSpentGraphQLQuotaPausesTheEstateButNotRESTLookups() async throws {
        let reset = String(Int(Date().timeIntervalSince1970) + 3600)
        GitHubFixtureProtocol.fixture.reset(status: 200,
            body: #"{"data": null, "errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#,
            headers: ["X-RateLimit-Resource": "graphql", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": reset])
        let client = client()
        do { _ = try await client.estate(repos: ["owner/a"]); XCTFail("a spent quota returned an estate") }
        catch GitHubError.deferred {} // expected
        GitHubFixtureProtocol.fixture.reset(status: 200)
        let lookup = try await client.lookupPullRequests(number: 1744, repos: ["owner/a"])
        XCTAssertEqual(lookup.hits.first?.number, 1744, "REST keeps its own quota")
        XCTAssertEqual(GitHubFixtureProtocol.fixture.count, 1)
    }
}

private final class GitHubFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var status = 200
    private var override: (body: String, headers: [String: String])?
    var response: (body: String, headers: [String: String])? { lock.lock(); defer { lock.unlock() }; return override }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    func reset(status: Int, body: String? = nil, headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        requests = 0; self.status = status; override = body.map { ($0, headers) }
    }
    func start() -> Int { lock.lock(); defer { lock.unlock() }; requests += 1; return status }
}

private final class GitHubFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = GitHubFixture()
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.fixture.start()
        responseTask = Task {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let override = Self.fixture.response
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: override?.headers ?? (status == 429 ? ["Retry-After": "120"] : [:])) else { return }
            let body = override?.body ?? (status == 200 ? """
                {"number":1744,"title":"Cached search","html_url":"https://github.com/owner/a/pull/1744",
                 "state":"closed","merged_at":"2026-09-30T12:00:00Z","updated_at":"2026-09-30T12:00:00Z"}
                """ : "{\"message\":\"fixture refusal\"}")
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { responseTask?.cancel() }
}
