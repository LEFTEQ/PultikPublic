import Foundation
import CryptoKit

enum GitHubError: LocalizedError {
    case http(Int, String)
    case deferred(Date)

    var errorDescription: String? {
        switch self {
        case .http(let code, let path):
            return "GitHub API \(code) on \(path)"
        case .deferred(let until):
            return "GitHub polling paused to protect quota; retry after \(until.formatted(date: .omitted, time: .shortened))"
        }
    }
}

struct GitHubPRSearchResult: Sendable {
    let hits: [ArchivedPR]
    let complete: Bool
    let warning: String?
}

actor GitHubClient {
    private var token: String?
    private var tokenFetchedAt: Date?
    private let session: URLSession
    private let tokenProvider: @Sendable () throws -> String
    private let queue: GitHubRequestQueue
    private struct Pending {
        let id: UUID
        let task: Task<Data, Error>
        var subscribers: Set<UUID>
    }
    private var pending: [String: Pending] = [:]
    private(set) var networkRequests = 0
    private(set) var sharedRequests = 0
    private(set) var prLookupRequests = 0
    private(set) var prSearchRequests = 0

    init(session: URLSession = PollingSession.make(),
         queue: GitHubRequestQueue = GitHubRequestQueue(),
         tokenProvider: @escaping @Sendable () throws -> String = { try GHToken.fetch() }) {
        self.session = session
        self.queue = queue
        self.tokenProvider = tokenProvider
    }

    /// Digest only: the disk cache never stores credentials or an auth header.
    func cacheIdentity() throws -> String {
        Self.identity(for: try tokenValue())
    }

    private static func identity(for token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// A `gh auth token` that failed, kept with its time. Without this a broken
    /// login spawns the CLI once per REQUEST — and one refresh across seven
    /// pinned repos is over a hundred requests, so a logged-out gh meant a
    /// hundred process launches every 30 seconds.
    private var tokenFailure: (error: Error, at: Date)?
    private static let tokenRetryInterval: TimeInterval = 60

    private func tokenValue() throws -> String {
        if let token, let tokenFetchedAt,
           Date().timeIntervalSince(tokenFetchedAt) < Self.tokenRetryInterval { return token }
        if let failure = tokenFailure,
           Date().timeIntervalSince(failure.at) < Self.tokenRetryInterval {
            throw failure.error
        }
        do {
            let fetched = try tokenProvider()
            if token != nil, token != fetched { etagCache = GitHubResponseCache() }
            token = fetched
            tokenFetchedAt = Date()
            tokenFailure = nil
            return fetched
        } catch {
            tokenFailure = (error, Date())
            throw error
        }
    }

    /// Drops the cached token so the next request re-reads it from gh (e.g.
    /// after a 401).
    ///
    /// Rate-limited for the same reason: when a token goes stale EVERY
    /// in-flight request 401s at once, and an unthrottled invalidate would
    /// re-read gh, get the same rejected token, and do it again — once per
    /// request, for the whole refresh.
    private var lastInvalidated: Date?

    func invalidateToken() {
        if let last = lastInvalidated, Date().timeIntervalSince(last) < Self.tokenRetryInterval {
            return
        }
        lastInvalidated = Date()
        token = nil
    }

    // ETag cache: GitHub returns 304 Not Modified for unchanged resources,
    // and 304s do NOT count against the rate limit — poll cheaply.
    private var etagCache = GitHubResponseCache()
    private var budget = GitHubRequestBudget()

    /// `cache: false` keeps one-off paths (every distinct search query is one)
    /// out of the bounded ETag cache.
    private func request(_ path: String, method: String = "GET", cache: Bool = true,
                         priority: GitHubRequestQueue.Priority = .interactive,
                         polling: Bool? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard method == "GET" else {
            return try await performRequest(path, method: method, cache: cache,
                                            priority: priority, polling: false, authorization: try tokenValue())
        }
        let authorization = try tokenValue()
        let identity = Self.identity(for: authorization)
        let key = identity + "|" + path + "|" + String(cache)
        let subscriber = UUID()
        let flight: Pending
        if var existing = pending[key] {
            existing.subscribers.insert(subscriber)
            pending[key] = existing
            flight = existing
            sharedRequests += 1
        } else {
            let task = Task {
                try await self.performRequest(path, method: method, cache: cache,
                                              priority: priority, polling: polling ?? cache, authorization: authorization)
            }
            flight = Pending(id: UUID(), task: task, subscribers: [subscriber])
            pending[key] = flight
        }
        defer { unsubscribe(key: key, flightID: flight.id, subscriber: subscriber, cancelled: false) }
        return try await withTaskCancellationHandler {
            do {
                let data = try await flight.task.value
                try Task.checkCancellation()
                return data
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await self.unsubscribe(key: key, flightID: flight.id, subscriber: subscriber, cancelled: true) }
        }
    }

    private func unsubscribe(key: String, flightID: UUID, subscriber: UUID, cancelled: Bool) {
        guard var flight = pending[key], flight.id == flightID else { return }
        flight.subscribers.remove(subscriber)
        if flight.subscribers.isEmpty {
            pending.removeValue(forKey: key)
            if cancelled { flight.task.cancel() }
        } else { pending[key] = flight }
    }

    private func performRequest(_ path: String, method: String, cache: Bool,
                                priority: GitHubRequestQueue.Priority, polling: Bool, authorization: String) async throws -> Data {
        let resource = path.hasPrefix("/search/") ? "search" : "core"
        // Bind the credential before queueing. An account switch while this
        // request waits must not put the new account's data in the old cache.
        let slot = UUID()
        try await queue.acquire(id: slot, resource: resource, priority: priority)
        do {
            let data = try await send(path, method: method, cache: cache, resource: resource,
                                      polling: polling, authorization: authorization)
            await queue.release(id: slot)
            return data
        } catch {
            await queue.release(id: slot)
            throw error
        }
    }

    private func send(_ path: String, method: String, cache: Bool, resource: String,
                      polling: Bool, authorization: String) async throws -> Data {
        try Task.checkCancellation()
        if let until = budget.admit(resource: resource, polling: polling,
                                    mutation: method != "GET", now: Date()) {
            throw GitHubError.deferred(until)
        }
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // Hold the exact body whose validator we send across the await.
        // Actor reentrancy lets another response evict or replace this path.
        let cacheKey = Self.identity(for: authorization) + "|" + path
        let cached = method == "GET" && cache ? etagCache.value(for: cacheKey) : nil
        if let cached {
            req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        networkRequests += 1
        let parts = path.split(separator: "/")
        if method == "GET", parts.count == 5, parts[3] == "pulls", Int(parts[4]) != nil {
            prLookupRequests += 1
        }
        if resource == "search", let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value, q.hasPrefix("is:pr ") {
            prSearchRequests += 1
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(-1, path)
        }
        let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let limited = http.statusCode == 403 && String(decoding: data, as: UTF8.self)
            .localizedCaseInsensitiveContains("rate limit")
        budget.observe(status: http.statusCode,
                       resource: http.value(forHTTPHeaderField: "X-RateLimit-Resource") ?? resource,
                       remaining: remaining, reset: reset, retryAfter: retryAfter,
                       rateLimited: limited, now: Date())
        if http.statusCode == 429 || limited {
            throw GitHubError.deferred(budget.blockedUntil(resource: resource, now: Date()) ?? Date().addingTimeInterval(60))
        }
        if http.statusCode == 304, let cached {
            return cached.data
        }
        if http.statusCode == 401 { invalidateToken() }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, path)
        }
        if method == "GET", cache, let etag = http.value(forHTTPHeaderField: "ETag") {
            etagCache.insert(.init(etag: etag, data: data), for: cacheKey)
        }
        return data
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ path: String, cache: Bool = true,
                                     priority: GitHubRequestQueue.Priority = .interactive,
                                     polling: Bool? = nil) async throws -> T {
        try decoder.decode(T.self, from: try await request(path, cache: cache, priority: priority, polling: polling))
    }

    // MARK: - Reads

    /// Use a real authenticated endpoint: /rate_limit can report a full
    /// budget even while ordinary requests are rejected. Admission still
    /// honors a known server deadline before this one-request trial.
    func probeHealth() async -> ProbeFailure? {
        do {
            _ = try await request("/user", cache: false)
            return nil
        } catch {
            return .classify(error)
        }
    }

    func workflowRuns(repo: String) async throws -> [WorkflowRun] {
        try await fetch(WorkflowRunsResponse.self, "/repos/\(repo)/actions/runs?per_page=10", priority: .background).workflowRuns
    }

    /// Latest deployment per environment, each with its most recent status.
    func deployments(repo: String) async throws -> [DeployInfo] {
        let deployments = try await fetch([Deployment].self, "/repos/\(repo)/deployments?per_page=10", priority: .background)
        let latestPerEnv = Dictionary(grouping: deployments, by: \.environment)
            .compactMap { $0.value.max(by: { $0.createdAt < $1.createdAt }) }
            .sorted { $0.createdAt > $1.createdAt }

        var infos: [DeployInfo] = []
        for deployment in latestPerEnv.prefix(4) {
            let statuses = try await fetch(
                [DeploymentStatus].self,
                "/repos/\(repo)/deployments/\(deployment.id)/statuses?per_page=1", priority: .background
            )
            let status = statuses.first
            infos.append(DeployInfo(
                deployment: deployment,
                state: status?.state ?? "pending",
                url: status?.environmentUrl ?? status?.targetUrl
            ))
        }
        return infos
    }

    func pullRequests(repo: String) async throws -> [PRInfo] {
        let prs = try await fetch([PullRequest].self, "/repos/\(repo)/pulls?state=open&per_page=5", priority: .background)
        var infos: [PRInfo] = []
        for pr in prs {
            let checks = try await fetch(
                CheckRunsResponse.self,
                "/repos/\(repo)/commits/\(pr.head.sha)/check-runs?per_page=50", priority: .background
            ).checkRuns
            let state: CheckState
            if checks.isEmpty {
                state = .none
            } else if checks.contains(where: { $0.status != "completed" }) {
                state = .running
            } else if checks.contains(where: { ["failure", "timed_out", "startup_failure"].contains($0.conclusion ?? "") }) {
                state = .failure
            } else {
                state = .success
            }
            infos.append(PRInfo(pr: pr, state: state, review: try await reviewState(repo: repo, number: pr.number)))
        }
        return infos
    }

    /// Latest APPROVED/CHANGES_REQUESTED/DISMISSED review per reviewer;
    /// changes-requested dominates, any approval counts, otherwise awaiting.
    private func reviewState(repo: String, number: Int) async throws -> ReviewState {
        let reviews = try await fetch([PRReview].self, "/repos/\(repo)/pulls/\(number)/reviews?per_page=50", priority: .background)
        var latest: [String: String] = [:]
        for review in reviews {
            guard let login = review.user?.login,
                  ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state) else { continue }
            latest[login] = review.state
        }
        if latest.values.contains("CHANGES_REQUESTED") { return .changesRequested }
        if latest.values.contains("APPROVED") { return .approved }
        return .awaiting
    }

    func discoverRepos() async throws -> [String] {
        let repos = try await fetch(
            [DiscoveredRepo].self,
            "/user/repos?sort=pushed&per_page=30&affiliation=owner,collaborator,organization_member"
        )
        return repos.map(\.fullName)
    }

    // MARK: - PR search (the archive)

    /// Full-text PR search across `repos`, every state — this is what makes a
    /// merged PR from three months ago findable from the palette.
    ///
    /// The repo list is OR'd inside one query and chunked: under
    /// `advanced_search` repeated `repo:` qualifiers are ANDed (a PR is never
    /// in two repos, so that silently returns nothing), and GitHub documents a
    /// 256-character / five-operator ceiling on `q`.
    func searchPullRequests(terms: String, repos: [String], limit: Int = 15) async throws -> GitHubPRSearchResult {
        let terms = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty, !repos.isEmpty else { return .init(hits: [], complete: true, warning: nil) }
        var found: [ArchivedPR] = []
        var warning: String?
        var failure: Error?
        for chunk in Self.repoChunks(repos) {
            try Task.checkCancellation()
            do {
                let page = try await search(terms: terms, chunk: chunk, limit: limit)
                found.append(contentsOf: page.hits)
                if !page.complete { warning = page.warning }
            } catch is CancellationError { throw CancellationError() }
            catch {
                failure = error
                warning = error.localizedDescription
                if case GitHubError.deferred = error { break }
                if case GitHubError.http(let code, _) = error, code == 401 || code == 403 { break }
            }
        }
        if found.isEmpty, let failure { throw failure }
        return .init(hits: Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)),
                     complete: warning == nil, warning: warning)
    }

    private func search(terms: String, chunk: [String], limit: Int) async throws -> GitHubPRSearchResult {
        let scope = chunk.map { "repo:\($0)" }.joined(separator: " OR ")
        let q = "is:pr (\(scope)) \(terms)"
        let path = "/search/issues?advanced_search=true&sort=updated&order=desc"
            + "&per_page=\(limit)&q=\(Self.encode(q))"
        let response = try await fetch(PRSearchResponse.self, path, cache: false)
        return .init(hits: response.items.map(ArchivedPR.init(item:)),
                     complete: response.incompleteResults != true,
                     warning: response.incompleteResults == true ? "GitHub returned partial search results" : nil)
    }

    func archivePage(repo: String, page: Int) async throws -> [ArchivedPR] {
        let prs = try await fetch([PRLookup].self,
            "/repos/\(repo)/pulls?state=all&sort=updated&direction=desc&per_page=100&page=\(page)",
            priority: .background)
        return prs.map { ArchivedPR(lookup: $0, repoSlug: repo) }
    }

    /// One search per repo chunk, run concurrently and merged. A partial answer
    /// beats an error banner, but never a silent one.
    private func chunked<T: Sendable>(
        repos: [String],
        what: String,
        perChunk: @Sendable @escaping ([String]) async throws -> [T]
    ) async throws -> [T] {
        let results = await withTaskGroup(of: Result<[T], Error>.self) { group in
            for chunk in Self.repoChunks(repos) {
                group.addTask {
                    do { return .success(try await perChunk(chunk)) }
                    catch { return .failure(error) }
                }
            }
            var collected: [Result<[T], Error>] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var found: [T] = []
        var failure: Error?
        for result in results {
            switch result {
            case .success(let items): found.append(contentsOf: items)
            case .failure(let error): failure = error
            }
        }
        if let failure {
            if found.isEmpty { throw failure }
            NSLog("pultik: %@ search partially failed: %@", what, failure.localizedDescription)
        }
        return found
    }

    // MARK: - Issue search (the .issues mode)

    /// Full-text issue search across `repos`, every state — the mode's typed
    /// query. Same chunking and partial-failure contract as the PR archive.
    func searchIssues(terms: String, repos: [String], limit: Int = 20) async throws -> [ArchivedIssue] {
        let terms = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty, !repos.isEmpty else { return [] }
        let found = try await chunked(repos: repos, what: "issue") { chunk in
            try await self.issueSearch(q: "\(Self.scope(chunk)) \(terms)", limit: limit)
        }
        return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// The mode's resting list: most recently touched issues across `repos`,
    /// no terms.
    ///
    /// Uncached like every other search: `/search/issues` sends no ETag and
    /// `cache-control: no-cache` (verified 2026-07-29), so there is no 304 to
    /// win here. The per-repo `/repos/{repo}/issues` endpoint *does* support
    /// ETags, but it has no server-side issue/PR filter — on a PR-heavy repo
    /// the newest page comes back all pull requests and the list renders empty.
    /// Precision wins: the five-minute gate spends ~12 calls an hour against a
    /// 30-per-MINUTE search budget.
    func recentIssues(repos: [String], limit: Int = 20) async throws -> [ArchivedIssue] {
        guard !repos.isEmpty else { return [] }
        let found = try await chunked(repos: repos, what: "recent issue") { chunk in
            try await self.issueSearch(q: Self.scope(chunk), limit: limit, priority: .background, polling: true)
        }
        return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private func issueSearch(q: String, limit: Int, priority: GitHubRequestQueue.Priority = .interactive,
                             polling: Bool = false) async throws -> [ArchivedIssue] {
        let path = "/search/issues?advanced_search=true&sort=updated&order=desc"
            + "&per_page=\(limit)&q=\(Self.encode(q))"
        return try await fetch(IssueSearchResponse.self, path, cache: false, priority: priority, polling: polling)
            .items.compactMap(ArchivedIssue.init(item:))
    }

    /// Exact-number lookup across `repos` — "812" means issue #812. The
    /// endpoint answers for pull requests too; `ArchivedIssue.init` drops those.
    /// Misses (404) are expected: the number only exists in some of the repos.
    ///
    /// `failure` is non-nil only when EVERY repo failed with a real error
    /// (not a 404) — one dead repo must not sink the other hits, but all of
    /// them failing is the host/token, and the caller's breaker needs it.
    func lookupIssues(number: Int, repos: [String]) async -> (hits: [ArchivedIssue], failure: ProbeFailure?) {
        await withTaskGroup(of: (hit: ArchivedIssue?, failure: ProbeFailure?).self) { group in
            for repo in repos {
                group.addTask {
                    do {
                        let issue = try await self.fetch(
                            IssueLookup.self, "/repos/\(repo)/issues/\(number)", cache: false
                        )
                        return (ArchivedIssue(lookup: issue, repoSlug: repo), nil)
                    } catch GitHubError.http(404, _) {
                        return (nil, nil) // no such issue in this repo
                    } catch {
                        NSLog("pultik: issue #%d lookup on %@ failed: %@",
                              number, repo, error.localizedDescription)
                        return (nil, .classify(error))
                    }
                }
            }
            var found: [ArchivedIssue] = []
            var failures: [ProbeFailure] = []
            for await result in group {
                if let hit = result.hit { found.append(hit) }
                if let failure = result.failure { failures.append(failure) }
            }
            return (found.sorted { $0.updatedAt > $1.updatedAt },
                    failures.count == repos.count ? failures.first : nil)
        }
    }

    /// "is:issue (repo:a OR repo:b …)" — the shared prefix of every issue query.
    private static func scope(_ chunk: [String]) -> String {
        "is:issue (\(chunk.map { "repo:\($0)" }.joined(separator: " OR ")))"
    }

    /// Exact-number lookup across `repos` — "520" means PR #520, which no
    /// full-text search will reliably surface. Misses (404) are expected: the
    /// number only exists in some of the repos. Same all-failed `failure`
    /// contract as `lookupIssues`.
    func lookupPullRequests(number: Int, repos: [String]) async throws
        -> (hits: [ArchivedPR], confirmedRepos: [String], warning: String?, failure: ProbeFailure?) {
        var found: [ArchivedPR] = []
        var confirmed: [String] = []
        var warning: String?
        var failure: ProbeFailure?
        for repo in repos {
            try Task.checkCancellation()
            do {
                let pr = try await fetch(PRLookup.self, "/repos/\(repo)/pulls/\(number)", cache: false)
                found.append(ArchivedPR(lookup: pr, repoSlug: repo))
                confirmed.append(repo)
            } catch is CancellationError { throw CancellationError() }
            catch GitHubError.http(404, _) { confirmed.append(repo) }
            catch {
                warning = error.localizedDescription
                failure = .classify(error)
                NSLog("pultik: PR #%d lookup on %@ failed: %@", number, repo, error.localizedDescription)
                // A known deadline applies to every remaining repo too.
                if case GitHubError.deferred = error { break }
                if case GitHubError.http(let code, _) = error, code == 401 || code == 403 { break }
            }
        }
        return (found.sorted { $0.updatedAt > $1.updatedAt }, confirmed, warning, failure)
    }

    /// Six repos per query: five `OR`s is GitHub's documented operator ceiling,
    /// and six slugs keep `q` comfortably inside the 256-character one.
    private static func repoChunks(_ repos: [String], size: Int = 6) -> [[String]] {
        stride(from: 0, to: repos.count, by: size).map {
            Array(repos[$0..<min($0 + size, repos.count)])
        }
    }

    /// `+` and `&` must not survive into the query string: GitHub reads a raw
    /// `+` as a space and a raw `&` would split the parameter.
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Actions

    func rerun(repo: String, runId: Int, failedJobsOnly: Bool) async throws {
        if failedJobsOnly {
            do {
                _ = try await request("/repos/\(repo)/actions/runs/\(runId)/rerun-failed-jobs", method: "POST")
                return
            } catch GitHubError.http(let code, _) where (400..<500).contains(code) {
                // no failed jobs to re-run (e.g. cancelled run) — fall through to full re-run
            }
        }
        _ = try await request("/repos/\(repo)/actions/runs/\(runId)/rerun", method: "POST")
    }

    func cancel(repo: String, runId: Int) async throws {
        _ = try await request("/repos/\(repo)/actions/runs/\(runId)/cancel", method: "POST")
    }
}
