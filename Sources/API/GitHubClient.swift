import Foundation

enum GitHubError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let path):
            return "GitHub API \(code) on \(path)"
        }
    }
}

actor GitHubClient {
    private var token: String?
    private let session = PollingSession.make()
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
        if let token { return token }
        if let failure = tokenFailure,
           Date().timeIntervalSince(failure.at) < Self.tokenRetryInterval {
            throw failure.error
        }
        do {
            let fetched = try GHToken.fetch()
            token = fetched
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

    /// `cache: false` keeps one-off paths (every distinct search query is one)
    /// out of the bounded ETag cache.
    private func request(_ path: String, method: String = "GET", cache: Bool = true) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try tokenValue())", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // Hold the exact body whose validator we send across the await.
        // Actor reentrancy lets another response evict or replace this path.
        let cached = method == "GET" && cache ? etagCache.value(for: path) : nil
        if let cached {
            req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(-1, path)
        }
        if http.statusCode == 304, let cached {
            return cached.data
        }
        if http.statusCode == 401 { invalidateToken() }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, path)
        }
        if method == "GET", cache, let etag = http.value(forHTTPHeaderField: "ETag") {
            etagCache.insert(.init(etag: etag, data: data), for: path)
        }
        return data
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ path: String, cache: Bool = true) async throws -> T {
        try decoder.decode(T.self, from: try await request(path, cache: cache))
    }

    // MARK: - Reads

    /// The half-open trial's single cheap request: GET /rate_limit proves
    /// DNS, TLS and the token without counting against quota — the ~120-
    /// request repo fan-out waits for this to say the host is answering.
    /// Returns the classified failure (nil = healthy) so a 401/403 on the
    /// trial re-arms the breaker as `.rejected`, not `.unreachable`.
    func probeHealth() async -> ProbeFailure? {
        do {
            _ = try await request("/rate_limit", cache: false)
            return nil
        } catch {
            return .classify(error)
        }
    }

    func workflowRuns(repo: String) async throws -> [WorkflowRun] {
        try await fetch(WorkflowRunsResponse.self, "/repos/\(repo)/actions/runs?per_page=10").workflowRuns
    }

    // MARK: - Runner → job resolution (lazy, popover-driven)

    /// runner_name → its in-progress job, scanned across the given repos.
    /// GitHub has no runner→run endpoint, so this walks every repo's
    /// `in_progress` runs and matches jobs by `runner_name` (spec 2026-08-27).
    /// Cached briefly: it only fires when a grid popover opens, but one hover
    /// session shouldn't re-scan nine repos per cell. Failures surface so the
    /// caller can feed ProbeGate — an all-repos miss is "GitHub isn't
    /// answering", never an empty answer.
    private var runnerJobsCache: (jobs: [String: RunnerJob], at: Date)?
    private var runnerJobsScan: Task<(jobs: [String: RunnerJob], failure: ProbeFailure?), Never>?
    private static let runnerJobsTTL: TimeInterval = 45

    func runnerJobs(repos: [String]) async -> (jobs: [String: RunnerJob], failure: ProbeFailure?) {
        if let cached = runnerJobsCache, Date().timeIntervalSince(cached.at) < Self.runnerJobsTTL {
            return (cached.jobs, nil)
        }
        // Actor methods re-enter at every await: a second popover opening
        // mid-scan would otherwise start its own full per-repo fan-out.
        // Everyone piles onto the one in-flight scan instead.
        if let scan = runnerJobsScan { return await scan.value }
        let scan = Task { await self.scanRunnerJobs(repos: repos) }
        runnerJobsScan = scan
        let result = await scan.value
        runnerJobsScan = nil
        if result.failure == nil { runnerJobsCache = (result.jobs, Date()) }
        return result
    }

    private func scanRunnerJobs(repos: [String]) async -> (jobs: [String: RunnerJob], failure: ProbeFailure?) {
        var map: [String: RunnerJob] = [:]
        var failures = 0
        var firstError: Error?
        await withTaskGroup(of: Result<[(String, RunnerJob)], Error>.self) { group in
            for repo in repos {
                group.addTask {
                    do { return .success(try await self.activeJobs(repo: repo)) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let pairs):
                    for (runner, job) in pairs { map[runner] = job }
                case .failure(let error):
                    failures += 1
                    if firstError == nil { firstError = error }
                }
            }
        }
        // A partial miss still answers (the found jobs are real); only a
        // clean sweep of failures is a breaker-worthy no-answer.
        if failures == repos.count, let firstError, !repos.isEmpty {
            return (map, .classify(firstError))
        }
        return (map, nil)
    }

    private func activeJobs(repo: String) async throws -> [(String, RunnerJob)] {
        // No pagination loops on a hover-latency path — but the single pages
        // sit at their practical ceilings (30 concurrent in-progress runs per
        // repo, 100 jobs per run = the API max).
        let runs = try await fetch(
            WorkflowRunsResponse.self,
            "/repos/\(repo)/actions/runs?status=in_progress&per_page=30"
        ).workflowRuns

        var pairs: [(String, RunnerJob)] = []
        for run in runs {
            // Run ids are one-shot paths — keep them out of the ETag map.
            let jobs = try await fetch(
                WorkflowJobsResponse.self,
                "/repos/\(repo)/actions/runs/\(run.id)/jobs?per_page=100",
                cache: false
            ).jobs
            for job in jobs where job.status == "in_progress" {
                guard let runner = job.runnerName else { continue }
                pairs.append((runner, RunnerJob(
                    repo: repo,
                    workflowName: run.name,
                    jobName: job.name,
                    htmlUrl: job.htmlUrl ?? run.htmlUrl,
                    startedAt: job.startedAt)))
            }
        }
        return pairs
    }

    /// Latest deployment per environment, each with its most recent status.
    func deployments(repo: String) async throws -> [DeployInfo] {
        let deployments = try await fetch([Deployment].self, "/repos/\(repo)/deployments?per_page=10")
        let latestPerEnv = Dictionary(grouping: deployments, by: \.environment)
            .compactMap { $0.value.max(by: { $0.createdAt < $1.createdAt }) }
            .sorted { $0.createdAt > $1.createdAt }

        var infos: [DeployInfo] = []
        for deployment in latestPerEnv.prefix(4) {
            let statuses = try await fetch(
                [DeploymentStatus].self,
                "/repos/\(repo)/deployments/\(deployment.id)/statuses?per_page=1"
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
        let prs = try await fetch([PullRequest].self, "/repos/\(repo)/pulls?state=open&per_page=5")
        var infos: [PRInfo] = []
        for pr in prs {
            let checks = try await fetch(
                CheckRunsResponse.self,
                "/repos/\(repo)/commits/\(pr.head.sha)/check-runs?per_page=50"
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
        let reviews = try await fetch([PRReview].self, "/repos/\(repo)/pulls/\(number)/reviews?per_page=50")
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
    func searchPullRequests(terms: String, repos: [String], limit: Int = 15) async throws -> [ArchivedPR] {
        let terms = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty, !repos.isEmpty else { return [] }
        let found = try await chunked(repos: repos, what: "PR") { chunk in
            try await self.search(terms: terms, chunk: chunk, limit: limit)
        }
        return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private func search(terms: String, chunk: [String], limit: Int) async throws -> [ArchivedPR] {
        let scope = chunk.map { "repo:\($0)" }.joined(separator: " OR ")
        let q = "is:pr (\(scope)) \(terms)"
        let path = "/search/issues?advanced_search=true&sort=updated&order=desc"
            + "&per_page=\(limit)&q=\(Self.encode(q))"
        return try await fetch(PRSearchResponse.self, path, cache: false)
            .items.map(ArchivedPR.init(item:))
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
            try await self.issueSearch(q: Self.scope(chunk), limit: limit)
        }
        return Array(found.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private func issueSearch(q: String, limit: Int) async throws -> [ArchivedIssue] {
        let path = "/search/issues?advanced_search=true&sort=updated&order=desc"
            + "&per_page=\(limit)&q=\(Self.encode(q))"
        return try await fetch(IssueSearchResponse.self, path, cache: false)
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
    func lookupPullRequests(number: Int, repos: [String]) async -> (hits: [ArchivedPR], failure: ProbeFailure?) {
        await withTaskGroup(of: (hit: ArchivedPR?, failure: ProbeFailure?).self) { group in
            for repo in repos {
                group.addTask {
                    do {
                        let pr = try await self.fetch(
                            PRLookup.self, "/repos/\(repo)/pulls/\(number)", cache: false
                        )
                        return (ArchivedPR(lookup: pr, repoSlug: repo), nil)
                    } catch GitHubError.http(404, _) {
                        return (nil, nil) // no such PR in this repo
                    } catch {
                        NSLog("pultik: PR #%d lookup on %@ failed: %@",
                              number, repo, error.localizedDescription)
                        return (nil, .classify(error))
                    }
                }
            }
            var found: [ArchivedPR] = []
            var failures: [ProbeFailure] = []
            for await result in group {
                if let hit = result.hit { found.append(hit) }
                if let failure = result.failure { failures.append(failure) }
            }
            return (found.sorted { $0.updatedAt > $1.updatedAt },
                    failures.count == repos.count ? failures.first : nil)
        }
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
