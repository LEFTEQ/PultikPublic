import Foundation

/// Semafor — the CI admission board (example-org/semafor), one per host
/// since 2026-10-14: each counts only its own host's lanes, and each server
/// names its own (`NamedRef.semafor`). Every instance is its own host, so
/// each has its own breaker (`ProbeTarget.semafor(host:)`). Its admission
/// view (the pools, the queue head, refusal reasons), its overview (today's
/// jobs and queue wait) and, since vt-7727, its v1 views — the estate map,
/// findings and backups, CI's lanes, live edge, runs, workflows, failures
/// and a run's graph — are read, only while a view draws them. No auth on
/// the query API; off-mesh the call fails fast and that view says so.
actor SemaforClient {
    static let shared = SemaforClient()

    private let session: URLSession
    /// Every request sent, by path — the debug driver's proof that nothing
    /// reads Semafor while the panel is hidden (vt-7727 AC 12). Read
    /// synchronously: `metrics` answers while the panel is down.
    nonisolated static let requests = RequestCounter()

    final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func add(_ path: String) { lock.withLock { counts[path, default: 0] += 1 } }
        var snapshot: [String: Int] { lock.withLock { counts } }
    }

    init() {
        session = PollingSession.make(timeout: 5)
    }

    /// The pool, its head labelled from the lanes' `ci_lane_info` tiers. A
    /// failure is what the breaker backs off on; an answer without a Docker
    /// pool (no controller exported yet) is a nil pool, not a failure.
    func pool(at base: URL, lanes: [CILane]) async -> (pool: CIPool?, failure: ProbeFailure?) {
        let data: Data
        let response: URLResponse
        do {
            Self.requests.add("admission")
            (data, response) = try await session.data(from: base.appending(path: "api/v1/admission"))
        } catch {
            return (nil, .classify(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let why = "semafor answered \(status)"
            return (nil, [401, 403, 429].contains(status) ? .rejected(why) : .unreachable(why))
        }
        guard let admission = SemaforAdmission.decode(data) else {
            return (nil, .unreachable("semafor admission payload unreadable"))
        }
        return (admission.pool(lanes: lanes), nil)
    }

    /// Today's throughput and queue wait — `/api/v1/overview`. Semafor's own
    /// SPA reads it once a minute; the store keeps to the same cadence.
    func overview(at base: URL) async -> (throughput: CIThroughput?, failure: ProbeFailure?) {
        let data: Data
        let response: URLResponse
        do {
            Self.requests.add("overview")
            (data, response) = try await session.data(from: base.appending(path: "api/v1/overview"))
        } catch {
            return (nil, .classify(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let why = "semafor overview answered \(status)"
            return (nil, [401, 403, 429].contains(status) ? .rejected(why) : .unreachable(why))
        }
        guard let throughput = CIThroughput.decode(data) else {
            return (nil, .unreachable("semafor overview payload unreadable"))
        }
        return (throughput, nil)
    }

    /// Each repo's job outcomes over Semafor's window (7 d) — `/api/v1/repos/health`.
    /// Read on a CI run's explicit selection (WP6), never polled; nil off-mesh.
    func repoHealth(at base: URL) async throws -> [SemaforRepoHealth] {
        let (data, response) = try await session.data(from: base.appending(path: "api/v1/repos/health"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try SemaforRepoHealth.decode(data)
    }

    // MARK: - v1 views (vt-7727 WP3)

    /// One read of Semafor's v1: the decoded value, or the failure the
    /// host's breaker backs off on. Only the Semafor lane calls these, and
    /// only while a view that draws them is on screen (D10).
    private func read<Value>(_ base: URL, _ path: String, _ query: [URLQueryItem] = [],
                             _ decode: (Data) throws -> Value) async -> (value: Value?, failure: ProbeFailure?)
    {
        var components = URLComponents(url: base.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { return (nil, .unreachable("bad semafor url")) }
        let data: Data
        let response: URLResponse
        do {
            Self.requests.add(path)
            (data, response) = try await session.data(from: url)
        } catch {
            return (nil, .classify(error))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let why = "semafor \(path) answered \(status)"
            return (nil, [401, 403, 429].contains(status) ? .rejected(why) : .unreachable(why))
        }
        do {
            return (try decode(data), nil)
        } catch {
            NSLog("pultik: semafor %@ unreadable — %@", path, String(describing: error))
            return (nil, .unreachable("semafor \(path) payload unreadable"))
        }
    }

    func estateMap(at base: URL) async -> (value: SemaforEstateMap?, failure: ProbeFailure?) {
        await read(base, "estate/map") { try SemaforTime.decoder().decode(SemaforEstateMap.self, from: $0) }
    }

    func findings(at base: URL) async -> (value: [SemaforFinding]?, failure: ProbeFailure?) {
        await read(base, "estate/findings", [], SemaforFinding.decode)
    }

    func backups(at base: URL) async -> (value: SemaforBackups?, failure: ProbeFailure?) {
        await read(base, "estate/backups") { try SemaforTime.decoder().decode(SemaforBackups.self, from: $0) }
    }

    func lanes(at base: URL) async -> (value: [SemaforCILane]?, failure: ProbeFailure?) {
        await read(base, "ci/lanes", [], SemaforCILane.decode)
    }

    /// The live edge: the hour of jobs before `now` (D10).
    func liveEdge(at base: URL, now: Date = Date()) async -> (value: SemaforTimelinePage?, failure: ProbeFailure?) {
        await read(base, "ci/timeline", [URLQueryItem(name: "before", value: SemaforTime.string(now)),
                                          URLQueryItem(name: "span", value: "3600")]) {
            try SemaforTime.decoder().decode(SemaforTimelinePage.self, from: $0)
        }
    }

    func runs(at base: URL, limit: Int = 50) async -> (value: [SemaforRun]?, failure: ProbeFailure?) {
        await read(base, "ci/runs", [URLQueryItem(name: "limit", value: "\(limit)")], SemaforRun.decode)
    }

    func workflows(at base: URL) async -> (value: SemaforWorkflows?, failure: ProbeFailure?) {
        await read(base, "ci/workflows", [URLQueryItem(name: "window", value: "7d")]) {
            try SemaforTime.decoder().decode(SemaforWorkflows.self, from: $0)
        }
    }

    func failures(at base: URL) async -> (value: SemaforFailures?, failure: ProbeFailure?) {
        await read(base, "ci/failures", [URLQueryItem(name: "window", value: "7d")]) {
            try SemaforTime.decoder().decode(SemaforFailures.self, from: $0)
        }
    }

    /// A run's jobs, needs graph and critical path — read on selection only.
    func run(at base: URL, id: Int64) async -> (value: SemaforRunDetail?, failure: ProbeFailure?) {
        await read(base, "ci/runs/\(id)", [], SemaforRunDetail.decode)
    }
}

/// One repo's row of Semafor's `/api/v1/repos/health`: how its CI jobs ended
/// over the window. Snake-case keys decode through explicit `CodingKeys`.
struct SemaforRepoHealth: Codable, Sendable, Equatable {
    let repo: String
    let total: Int
    let failureRate: Double
    let cancelRate: Double

    enum CodingKeys: String, CodingKey {
        case repo, total
        case failureRate = "failure_rate"
        case cancelRate = "cancel_rate"
    }

    static func decode(_ data: Data) throws -> [SemaforRepoHealth] {
        struct Answer: Decodable { let rows: [SemaforRepoHealth] }
        return try JSONDecoder().decode(Answer.self, from: data).rows
    }
}
