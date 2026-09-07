import Foundation
import Observation

@MainActor
@Observable
final class StatusStore {
    static let shared = StatusStore()

    /// Fired after any state change the menu bar icon depends on.
    var onChange: (() -> Void)?
    var onRefreshComplete: (() -> Void)?

    var repos: [RepoStatus] = []
    var pinned: [String] {
        didSet {
            var prefs = preferences
            prefs.pinnedRepos = pinned
            preferences = prefs
            prefs.save()
        }
    }

    private var preferences: Preferences
    var suggestions: [String] = []
    var prodIssues: [ProdIssue] = []
    var eveSessions: [EveSession] = []
    var serverMetrics: [ServerMetrics] = []
    var serviceStatuses: [ServiceStatus] = []
    var runnerCells: [RunnerCell] = []
    var vitrinkaListening: [VitrinkaListening] = []
    var eveAlerts: [EveAlert] = []
    /// ws-v2 workspaces are the primary Devbox surface. The remaining project
    /// list carries only slot-0 shared stacks and SampleStack's v2 stack slots.
    var devboxWorkspaces: [DevboxWorkspace] = []
    var devboxProjects: [DevboxProject] = []
    var devboxSummary: DevboxOverviewSummary?
    /// When the hub payload was generated ON THE BOX — the rail's "as of"
    /// stamp. The user asked for real status; real status carries its age.
    var devboxFetchedAt: Date?
    var lastRefresh: Date?
    /// When a refresh last RAN, as opposed to when it last produced data —
    /// the floor `refreshIfStale` enforces on panel opens.
    private var lastRefreshAttempt: Date?
    private var lastSentryRefresh: Date?
    var isRefreshing = false
    var globalError: String?

    private let client = GitHubClient()
    /// Circuit breaker in front of every remote host Pultík polls — including
    /// GitHub, which won't ban the machine but will happily let a broken token
    /// burn the hourly budget a hundred requests at a time.
    private let gate = ProbeGate.shared
    // runId → was-running, used to notify only on observed transitions
    private var previousRunning: [Int: Bool] = [:]
    private var previousDeployRunning: [Int: Bool] = [:]
    /// Last overview's parked count, for the pressure-park notification.
    /// nil until the first snapshot so a launch never announces history.
    private var previousDevboxParked: Int?
    /// Sentry issue ids already seen — notify only on genuinely new issues,
    /// and never on the first load after launch.
    private var seenSentryIssues: Set<String>?
    // Eve alert ids already fetched this app run — same idiom: notify only on
    // genuinely new visible-lane alerts, first load silent. Read-state proper
    // (the unread badge) is AlertSeenStore, which persists.
    private var notifiedAlertIds: Set<Int>?
    private var pollTask: Task<Void, Never>?

    init() {
        let prefs = Preferences.load()
        preferences = prefs
        pinned = prefs.pinnedRepos
    }

    var aggregate: AggregateState {
        let failed = repos.reduce(0) { $0 + $1.failedCount }
        let running = repos.reduce(0) { $0 + $1.runningCount }
        if failed > 0 { return .failed(failed) }
        if running > 0 { return .running(running) }
        return .allClear
    }

    var anyRunning: Bool {
        repos.contains { $0.runningCount > 0 }
    }

    /// One PR of the cross-repo inbox, carrying its repo and its eve session.
    struct InboxPR: Identifiable {
        let repoSlug: String
        let info: PRInfo
        let eveSession: EveSession?
        var id: Int {
            info.id
        }

        /// "example-org/ExampleApp" → "ExampleApp"
        var repoName: String {
            repoSlug.split(separator: "/").last.map(String.init) ?? repoSlug
        }
    }

    /// The PR-first inbox: every open PR across pinned repos, eve-session
    /// attached, in FIXED repo order — `preferences.repoOrder` first, exactly
    /// as written; unlisted repos follow by recency (newest open PR); PRs
    /// within a repo newest-first. A repo's PRs are always in the same place,
    /// so the eye can go straight to them.
    var inbox: [InboxPR] {
        let sessionsByPR = Dictionary(
            eveSessions.compactMap { session in session.prKey.map { ($0, session) } },
            uniquingKeysWith: { a, b in
                (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast) ? a : b
            }
        )
        // Recency proxy for unlisted repos: the highest open-PR number —
        // GitHub has no cross-repo clock in this payload, but "which repo
        // opened work most recently" is stable and close enough.
        let newestPR = Dictionary(uniqueKeysWithValues: repos.map { repo in
            (repo.slug, repo.prs.map(\.pr.number).max() ?? 0)
        })
        func rank(_ slug: String) -> Int {
            let lower = slug.lowercased()
            return preferences.repoOrder.firstIndex { lower.contains($0.lowercased()) }
                ?? preferences.repoOrder.count
        }
        return repos
            .flatMap { repo in
                repo.prs.map { info in
                    InboxPR(
                        repoSlug: repo.slug,
                        info: info,
                        eveSession: sessionsByPR["\(repo.slug)#\(info.pr.number)".lowercased()]
                    )
                }
            }
            .sorted { a, b in
                let ra = rank(a.repoSlug), rb = rank(b.repoSlug)
                if ra != rb { return ra < rb }
                if a.repoSlug != b.repoSlug {
                    let na = newestPR[a.repoSlug] ?? 0, nb = newestPR[b.repoSlug] ?? 0
                    if na != nb { return na > nb }
                    return a.repoSlug < b.repoSlug
                }
                return a.info.pr.number > b.info.pr.number
            }
    }

    // MARK: - PR search (the archive)

    var searchResults: [ArchivedPR] = []
    var isSearching = false
    var searchError: String?
    private var searchTask: Task<Void, Never>?
    private var searchQuery = ""

    /// Every repo a search may reach: the pinned ones first, then the project
    /// registry's — a project repo is "active" even when it isn't pinned to
    /// the dashboard (BookingBack has no tile but its PRs are still ours).
    var searchableRepos: [String] {
        var seen = Set<String>()
        return (pinned + preferences.projects.flatMap(\.repos))
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Search hits that aren't already on the dashboard above — the open PRs
    /// live in the inbox, so the archive section shows what the inbox can't.
    var searchMatches: [ArchivedPR] {
        let onDashboard = Set(inbox.map { "\($0.repoSlug)#\($0.info.pr.number)".lowercased() })
        return searchResults.filter { !onDashboard.contains($0.id.lowercased()) }
    }

    /// Debounced GitHub-wide PR search, driven by the palette on every
    /// keystroke. Nothing is fetched until typing settles and the query is
    /// worth a request — an empty palette never spends an API call, which is
    /// why closed PRs are absent until you actually look for one.
    func search(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sentry rides the same keystrokes but keeps its own task and state —
        // GitHub being slow or erroring must not delay or blank prod hits.
        searchSentry(query)
        guard query != searchQuery else { return }
        searchQuery = query
        searchTask?.cancel()

        // The breaker holds for typing too — a keystroke-driven search is the
        // fastest way to turn one refused request into fifty.
        guard query.count >= 2, !gate.isPaused(.github) else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [client] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let repos = searchableRepos
            do {
                let found: [ArchivedPR]
                if let number = Self.typedNumber(in: query) {
                    let lookup = await client.lookupPullRequests(number: number, repos: repos)
                    // The lookups swallow per-repo errors internally — the
                    // all-repos failure signal is the breaker's only view.
                    if let failure = lookup.failure { gate.failed(.github, failure) }
                    found = lookup.hits
                } else {
                    found = try await client.searchPullRequests(terms: query, repos: repos)
                }
                guard !Task.isCancelled, query == searchQuery else { return }
                searchResults = found
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                // A palette failure is a host failure like any other — feed
                // the breaker, or a refusal first seen here never opens it
                // and every further keystroke keeps knocking.
                gate.failed(.github, .classify(error))
                guard query == searchQuery else { return }
                searchResults = []
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    /// "520" and "#520" mean item number 520; anything else is full text.
    private static func typedNumber(in query: String) -> Int? {
        Int(query.hasPrefix("#") ? String(query.dropFirst()) : query)
    }

    // MARK: - Sentry search (palette full text)

    var sentryResults: [ProdIssue] = []
    var isSearchingSentry = false
    private var sentrySearchTask: Task<Void, Never>?
    private var sentryQuery = ""

    /// Search hits that aren't already on the prod strip above — same contract
    /// as `searchMatches`: the section shows what the dashboard can't.
    var sentryMatches: [ProdIssue] {
        let onStrip = Set(prodIssues.map(\.id))
        return sentryResults.filter { !onStrip.contains($0.id) }
    }

    /// Debounced org-wide Sentry search — resolves short ids ("EXAMPLEAPP-API-86")
    /// and full text alike. Same cancel/stale-guard contract as `search(_:)`.
    private func searchSentry(_ query: String) {
        guard query != sentryQuery else { return }
        sentryQuery = query
        sentrySearchTask?.cancel()

        // A paused breaker holds for typing too: a keystroke-driven search is
        // the fastest way to turn one refused request into fifty.
        guard query.count >= 2, isSectionVisible("prod"), !gate.isPaused(.sentry) else {
            sentryResults = []
            isSearchingSentry = false
            return
        }

        isSearchingSentry = true
        // `sentryToken`, never `preferences.sentryToken`: the keychain is the
        // runtime store and the legacy plaintext copy is blanked on migration.
        let settingsToken = sentryToken
        sentrySearchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let found = try await SentryClient.shared.searchIssues(query, settingsToken: settingsToken)
                guard !Task.isCancelled, query == sentryQuery else { return }
                sentryResults = found.map { ProdIssue(project: $0.project?.slug ?? "", issue: $0) }
            } catch {
                guard !Task.isCancelled else { return }
                // Feed the breaker: a refusal first seen from the palette
                // must open it like a poll failure would.
                gate.failed(.sentry, .classify(error))
                guard query == sentryQuery else { return }
                // Off-mesh every keystroke fails — hide like the prod strip
                // does rather than painting the palette red, but keep the why.
                NSLog("pultik: sentry search failed: %@", error.localizedDescription)
                sentryResults = []
            }
            isSearchingSentry = false
        }
    }

    // MARK: - Issue search (the .issues mode)

    /// The mode's resting list: most recently touched issues across the same
    /// repos, kept warm by the poll loop so `.issues` opens with something to
    /// scan instead of an empty box.
    var recentIssues: [ArchivedIssue] = []
    var isPrefetchingIssues = false
    private var lastIssueRefresh: Date?

    var issueResults: [ArchivedIssue] = []
    var isSearchingIssues = false
    var issueSearchError: String?
    private var issueSearchTask: Task<Void, Never>?
    private var issueQuery = ""
    /// Session-lifetime LRU of query → hits: backspacing through a query, or
    /// re-running one, redraws instead of re-hitting GitHub. A few minutes of
    /// staleness is irrelevant on an archive.
    private var issueCache: [String: [ArchivedIssue]] = [:]
    private var issueCacheOrder: [String] = []
    private static let issueCacheLimit = 20

    /// What the mode renders: the typed query's hits, or the resting list when
    /// nothing is typed yet.
    /// A one-character filter is too short to search, so it narrows the resting
    /// list locally rather than emptying the mode.
    var issueMatches: [ArchivedIssue] {
        showingRecentIssues ? recentIssues : issueResults
    }

    /// True while the mode is showing the prefetched list rather than a search.
    var showingRecentIssues: Bool {
        issueQuery.count < 2
    }

    /// Debounced issue search, driven by the `.issues` filter on every
    /// keystroke. Same cancel/stale-guard contract as `search(_:)` — nothing is
    /// fetched outside the mode, so default typing costs nothing.
    func searchIssues(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != issueQuery else { return }
        issueQuery = query
        issueSearchTask?.cancel()

        guard query.count >= 2, !gate.isPaused(.github) else {
            issueResults = []
            issueSearchError = nil
            isSearchingIssues = false
            return
        }
        if let cached = cachedIssues(query) {
            issueResults = cached
            issueSearchError = nil
            isSearchingIssues = false
            return
        }

        isSearchingIssues = true
        issueSearchTask = Task { [client] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let repos = searchableRepos
            // Captured WITH the request: these are the repos the hits will have
            // come from, whatever the scope is by the time they land.
            let cacheKey = Self.issueCacheKey(repos: repos, query: query)
            do {
                let found: [ArchivedIssue]
                if let number = Self.typedNumber(in: query) {
                    let lookup = await client.lookupIssues(number: number, repos: repos)
                    if let failure = lookup.failure { gate.failed(.github, failure) }
                    found = lookup.hits
                } else {
                    found = try await client.searchIssues(terms: query, repos: repos)
                }
                // A superseded task must not clear the newer one's spinner.
                guard !Task.isCancelled, query == issueQuery else { return }
                issueResults = found
                issueSearchError = nil
                remember(cacheKey, found)
            } catch {
                guard !Task.isCancelled else { return }
                gate.failed(.github, .classify(error))
                guard query == issueQuery else { return }
                issueResults = []
                issueSearchError = error.localizedDescription
            }
            isSearchingIssues = false
        }
    }

    /// Scope + text, never text alone: the repo set is user-editable through
    /// pin/unpin and the project registry, so a query cached under one scope
    /// must not answer under another — that would serve hits from repos just
    /// removed and hide ones just added, for the rest of the session.
    ///
    /// Takes `repos` explicitly rather than reading `searchableRepos`: a write
    /// happens after the await, so re-reading it there would file results under
    /// whatever scope is current at *completion* — not the one they were
    /// fetched under. The caller captures the scope with the request.
    private static func issueCacheKey(repos: [String], query: String) -> String {
        repos.joined(separator: ",").lowercased() + "|" + query.lowercased()
    }

    private func cachedIssues(_ query: String) -> [ArchivedIssue]? {
        // A READ is correctly keyed by the scope in force right now.
        let key = Self.issueCacheKey(repos: searchableRepos, query: query)
        guard let hits = issueCache[key] else { return nil }
        // A hit is a use: move it to the young end so it survives eviction.
        issueCacheOrder.removeAll { $0 == key }
        issueCacheOrder.append(key)
        return hits
    }

    private func remember(_ key: String, _ found: [ArchivedIssue]) {
        if issueCache[key] == nil { issueCacheOrder.append(key) }
        issueCache[key] = found
        while issueCacheOrder.count > Self.issueCacheLimit {
            issueCache.removeValue(forKey: issueCacheOrder.removeFirst())
        }
    }

    /// Entering the mode with nothing prefetched — first launch, or a sweep
    /// that failed — should not show an empty box. The five-minute gate still
    /// applies, so a failing sweep backs off instead of retrying per entry.
    func warmIssuesIfNeeded() {
        guard recentIssues.isEmpty else { return }
        Task { await refreshIssuesIfStale() }
    }

    /// Prefetch behind a five-minute gate, same idiom as the Sentry refresh.
    /// ~12 calls an hour against a 30-per-minute search budget — the gate is
    /// there to keep the poll loop from spending it, not because it's tight.
    private func refreshIssuesIfStale() async {
        if let last = lastIssueRefresh, Date().timeIntervalSince(last) < 300 { return }
        let repos = searchableRepos
        guard !repos.isEmpty, !gate.isPaused(.github) else { return }
        // Stamped before the call so a failing prefetch backs off too, instead
        // of retrying on every 30s poll.
        lastIssueRefresh = Date()
        isPrefetchingIssues = true
        defer { isPrefetchingIssues = false }
        do {
            recentIssues = try await client.recentIssues(repos: repos)
        } catch {
            NSLog("pultik: recent-issue prefetch failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                let interval: Duration = anyRunning ? .seconds(30) : .seconds(90)
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Runs a remote subsystem's fetch unless its breaker is open.
    ///
    /// Everything Pultík polls lives behind one of these. `work` returns the
    /// failure that made it come back empty, or nil; on a half-open `trial`
    /// only the single cheap `probe` request goes out, and the fan-out waits
    /// for it to prove the host is answering again. The probe returns the
    /// CLASSIFIED failure (or nil for success) — a 403 seen on a trial must
    /// re-arm the pause as `.rejected`, not be flattened to "not answering".
    private func gated(
        _ target: ProbeTarget,
        probe: () async -> ProbeFailure? = { nil },
        work: () async -> ProbeFailure?
    ) async {
        switch gate.verdict(target) {
        case .hold:
            return
        case .trial:
            if let failure = await probe() {
                gate.failed(target, failure)
                return
            }
            gate.succeeded(target)
        case .go:
            break
        }
        if let failure = await work() {
            gate.failed(target, failure)
        } else {
            gate.succeeded(target)
        }
    }

    /// Refresh unless one just happened.
    ///
    /// Opening the panel refreshes, and the panel is a ⌥Space away — without a
    /// floor, toggling it a dozen times fires a dozen full fan-outs (over a
    /// thousand GitHub requests) for data that cannot have changed. The footer
    /// button and every explicit action still call `refresh()` directly.
    func refreshIfStale(minimumInterval: TimeInterval = 15) async {
        // Deliberately NOT `lastRefresh`: that one tracks when the inbox data
        // last changed hands and stops advancing while GitHub is paused, which
        // would quietly re-open the floodgate for every other subsystem.
        if let last = lastRefreshAttempt, Date().timeIntervalSince(last) < minimumInterval { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshAttempt = Date()
        defer {
            isRefreshing = false
            onRefreshComplete?()
        }

        let slugs = pinned
        guard !slugs.isEmpty else {
            repos = []
            lastRefresh = Date()
            return
        }

        // The widest fan-out in the app: each repo costs up to 17 requests
        // (runs, deployments + their statuses, PRs + per-PR checks and
        // reviews), so seven pinned repos are ~120 requests per refresh. ETags
        // make that nearly free while GitHub is answering — and a token that
        // stops working turns every one of them into a counted 401.
        await gated(.github, probe: { [client] in await client.probeHealth() }) {
            let statuses = await withTaskGroup(of: (status: RepoStatus, failure: ProbeFailure?).self) { group in
                var remaining = slugs.makeIterator()
                // Bound simultaneous response decoding across a large estate.
                // Preserve pinned order below while keeping four repos moving.
                for _ in 0..<4 {
                    guard let slug = remaining.next() else { break }
                    group.addTask { [client] in
                        await Self.fetchRepo(slug: slug, client: client)
                    }
                }
                var collected: [String: (status: RepoStatus, failure: ProbeFailure?)] = [:]
                for await result in group {
                    collected[result.status.slug] = result
                    if let slug = remaining.next() {
                        group.addTask { [client] in
                            await Self.fetchRepo(slug: slug, client: client)
                        }
                    }
                }
                return slugs.compactMap { collected[$0] } // keep pinned order
            }

            for result in statuses where result.status.error != nil {
                NSLog("pultik: %@ error: %@", result.status.slug, result.status.error ?? "")
            }
            let fetched = statuses.map(\.status)
            notifyTransitions(fetched)
            repos = fetched
            // Stamped HERE, not once per poll: while GitHub is paused the
            // inbox is not refreshing, and a footer reading "just now" over
            // half-hour-old runs would be a lie the pause badge can't undo.
            lastRefresh = Date()
            onChange?()
            globalError = fetched.allSatisfy { $0.error != nil } && !fetched.isEmpty
                ? fetched.first?.error
                : nil

            // One repo erroring is a repo problem (renamed, revoked, deleted)
            // and must not silence the other six. All of them failing is
            // GitHub, the token, or the network — that is worth backing off.
            guard fetched.allSatisfy({ $0.error != nil }) else { return nil }
            return statuses.compactMap(\.failure).first ?? .unreachable("no answer from GitHub")
        }

        await refreshEve()
        await refreshInfraMetrics()
        await refreshVitrinka()
        await refreshDevbox()
        await refreshSentryIfStale()
        await refreshIssuesIfStale()
    }

    private nonisolated static func fetchRepo(
        slug: String, client: GitHubClient
    ) async -> (status: RepoStatus, failure: ProbeFailure?) {
        var status = RepoStatus(slug: slug)
        do {
            async let runs = client.workflowRuns(repo: slug)
            async let deploys = client.deployments(repo: slug)
            async let prs = client.pullRequests(repo: slug)
            status.runs = try Self.displayRuns(await runs)
            status.deploys = try await deploys
            status.prs = try await prs
        } catch {
            status.error = error.localizedDescription
            return (status, .classify(error))
        }
        return (status, nil)
    }

    /// Running runs + recent (24h) completed ones, capped at 5, always at least the latest.
    private nonisolated static func displayRuns(_ runs: [WorkflowRun]) -> [WorkflowRun] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var shown = runs.filter { $0.isRunning || $0.createdAt > cutoff }
        if shown.isEmpty, let latest = runs.first {
            shown = [latest]
        }
        return Array(shown.prefix(5))
    }

    // MARK: - Notifications

    private func notifyTransitions(_ statuses: [RepoStatus]) {
        for status in statuses {
            for run in status.runs {
                let wasRunning = previousRunning[run.id]
                if wasRunning == true, !run.isRunning, run.failed {
                    Notifier.send(
                        title: "\(status.slug) — run failed",
                        body: "\(run.name ?? "workflow") · \(run.headBranch ?? "?")",
                        url: run.htmlUrl
                    )
                }
                previousRunning[run.id] = run.isRunning
            }
            for deploy in status.deploys {
                let wasRunning = previousDeployRunning[deploy.id]
                if wasRunning == true, !deploy.isRunning {
                    Notifier.send(
                        title: "\(status.slug) — deploy \(deploy.state)",
                        body: "\(deploy.deployment.environment) · \(deploy.deployment.ref)",
                        url: deploy.url
                    )
                }
                previousDeployRunning[deploy.id] = deploy.isRunning
            }
        }
    }

    func enableLoginItemOnFirstRun() {
        let bundleId = Bundle.main.bundleIdentifier ?? "pultik"
        guard preferences.loginItemConfiguredFor != bundleId else { return }
        LoginItem.setEnabled(true)
        preferences.loginItemConfiguredFor = bundleId
        preferences.save()
    }

    // MARK: - Sentry (prod issues)

    /// Unresolved production issues across the configured projects — throttled
    /// to every 5 minutes; new issues (after the first load) notify.
    private func refreshSentryIfStale() async {
        if let last = lastSentryRefresh, Date().timeIntervalSince(last) < 300 { return }
        let projects = preferences.sentryProjects
        // `sentryToken`, never `preferences.sentryToken`: the keychain is the
        // runtime store and the legacy plaintext copy is blanked on migration.
        let settingsToken = sentryToken
        guard !projects.isEmpty else { return }

        await gated(.sentry, probe: {
            await SentryClient.shared.probeHealth(settingsToken: settingsToken)
        }) {
            let collected = await withTaskGroup(of: ProbeResult<[ProdIssue]>.self) { group in
                for project in projects {
                    group.addTask {
                        do {
                            let issues = try await SentryClient.shared.unresolvedIssues(
                                project: project, settingsToken: settingsToken
                            )
                            return .value(issues.map { ProdIssue(project: project, issue: $0) })
                        } catch {
                            // Off-mesh / token missing: prod strip just stays empty.
                            NSLog("pultik: sentry %@ failed: %@", project, error.localizedDescription)
                            return .failed(.classify(error))
                        }
                    }
                }
                var all: [ProdIssue] = []
                var failures: [ProbeFailure] = []
                for await result in group {
                    switch result {
                    case let .value(issues): all.append(contentsOf: issues)
                    case let .failed(failure): failures.append(failure)
                    }
                }
                return (issues: all, failures: failures)
            }

            // One project failing is a project problem (permissions, a typo in
            // the slug); ALL of them failing is a host problem, and only that
            // is worth pulling the whole strip off Sentry for.
            guard collected.failures.count < projects.count else {
                lastSentryRefresh = Date()
                return collected.failures.first
            }

            // "Major" means CURRENT: unresolved is forever in Sentry, so keep only
            // issues actually seen in the last 24h (kills months-old test noise).
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            let sorted = collected.issues
                .filter { $0.issue.lastSeen > cutoff }
                .sorted { $0.issue.lastSeen > $1.issue.lastSeen }
            if let seen = seenSentryIssues {
                for prodIssue in sorted where !seen.contains(prodIssue.id) {
                    Notifier.send(
                        title: "\(prodIssue.productLabel) prod — \(prodIssue.issue.shortId)",
                        body: prodIssue.issue.title,
                        url: prodIssue.issue.permalink
                    )
                }
            }
            seenSentryIssues = (seenSentryIssues ?? []).union(sorted.map(\.id))
            prodIssues = sorted
            lastSentryRefresh = Date()
            return nil
        }
    }

    // MARK: - Eve alerts (notifications ledger, WG mesh)

    /// Alerts in the lanes the user actually watches — newest first, as the
    /// ledger returns them. Every alert surface (rail, bar cell, badge,
    /// notify) works off this filtered view.
    var visibleAlerts: [EveAlert] {
        let lanes = Set(preferences.visibleAlertLanes)
        return eveAlerts.filter { lanes.contains($0.category) }
    }

    var unreadAlertIds: Set<Int> {
        Set(visibleAlerts.map(\.id).filter { !AlertSeenStore.shared.isSeen($0) })
    }

    var unreadAlertCount: Int {
        unreadAlertIds.count
    }

    /// A critical alert is unread — the badge and the bar cell go red.
    var unreadCriticalAlert: Bool {
        let unread = unreadAlertIds
        return visibleAlerts.contains { $0.severity == .critical && unread.contains($0.id) }
    }

    /// Panel opened with the alerts section visible — everything currently
    /// shown counts as seen. The badge clears; the rail keeps its unread
    /// styling from the snapshot the panel took before calling this.
    func markAlertsSeen() {
        AlertSeenStore.shared.markSeen(visibleAlerts.map(\.id))
        onChange?()
    }

    /// Both eve rails — PR sessions and the alerts ledger — behind ONE
    /// breaker: same host, so a refusal on either is a refusal for both, and
    /// the health endpoint is the cheapest way back in.
    private func refreshEve() async {
        await gated(.eve, probe: { [token = preferences.eveToken] in
            await EveClient.shared.probeHealth(settingsToken: token)
        }) {
            var failure: ProbeFailure?
            switch await EveClient.shared.prSessions(settingsToken: preferences.eveToken) {
            case let .failed(why): failure = why
            case let .value(sessions): eveSessions = sessions
            }
            // The ledger's verdict wins when it has one — it distinguishes a
            // refusal from silence, which the sessions call cannot.
            return await refreshEveAlerts() ?? failure
        }
    }

    private func refreshEveAlerts() async -> ProbeFailure? {
        guard isSectionVisible("alerts") else {
            eveAlerts = []
            return nil
        }
        // .failed = the fetch FAILED (off-mesh, endpoint absent): keep the last
        // known list, or a transient failure would resurrect every alert as
        // "new" on recovery. An EMPTY array is a real answer — the ledger is
        // clear — and must be allowed to empty the rail.
        let fetched: [EveAlert]
        switch await EveNotificationsClient.shared.recent(settingsToken: preferences.eveToken) {
        case let .failed(failure): return failure
        case let .value(alerts): fetched = alerts
        }
        let lanes = Set(preferences.visibleAlertLanes)
        if let notified = notifiedAlertIds {
            for alert in fetched.reversed()
                where lanes.contains(alert.category) && !notified.contains(alert.id)
            {
                Notifier.send(
                    title: "eve · \(alert.category)\(alert.severity == .critical ? " — critical" : "")",
                    body: alert.title,
                    url: nil
                )
            }
        }
        notifiedAlertIds = (notifiedAlertIds ?? []).union(fetched.map(\.id))
        eveAlerts = fetched
        if let floor = fetched.map(\.id).min() {
            AlertSeenStore.shared.prune(keepingAtOrAbove: floor)
        }
        onChange?()
        return nil
    }

    // MARK: - Infra metrics (mesh Prometheus)

    /// A dozen PromQL queries per refresh — by far the widest fan-out Pultík
    /// has, and worth the cheapest possible way back after a pause.
    private func refreshInfraMetrics() async {
        let servers = preferences.servers.map { (name: $0.name, instance: $0.ref) }
        let services = preferences.services.map { (name: $0.name, probe: $0.ref, host: $0.host) }
        await gated(.prometheus, probe: {
            await MetricsClient.shared.reachable()
                ? nil : .unreachable("prometheus not answering")
        }) {
            async let metrics = MetricsClient.shared.serverMetrics(servers: servers)
            async let statuses = MetricsClient.shared.serviceStatuses(services: services)
            (serverMetrics, serviceStatuses) = await (metrics, statuses)

            // Every configured server has node_exporter series and every
            // configured service a blackbox probe, so "asked about some, got
            // nothing back" is not an empty answer — it is no answer, and the
            // only failure signal these queries give.
            if !servers.isEmpty || !services.isEmpty,
               serverMetrics.isEmpty, serviceStatuses.isEmpty
            {
                runnerCells = []
                return .unreachable("no answer from Prometheus")
            }

            if isSectionVisible("runners") {
                runnerCells = await MetricsClient.shared.runnerGrid()
            } else {
                runnerCells = []
            }
            return nil
        }
    }

    /// The run currently executing on a runner — called when a grid popover
    /// opens, never from the poll loop (lazy per spec 2026-08-27; the client
    /// caches one scan briefly so a hover sweep costs one 9-repo pass).
    ///
    /// Same breaker as the poll loop: a held GitHub gate means a scan would
    /// deepen exactly the hole ProbeGate is backing out of, and the half-open
    /// trial belongs to `refresh()`'s cheap probe — never to this fan-out.
    func runnerJob(for cell: RunnerCell) async -> RunnerJob? {
        guard case .go = gate.verdict(.github) else { return nil }
        let result = await client.runnerJobs(repos: searchableRepos)
        if let failure = result.failure {
            gate.failed(.github, failure)
        }
        return result.jobs[cell.fullName]
    }

    // MARK: - Vitrinka listeners (own host, own breaker)

    /// One host, one credential, one breaker: the listener rail and the todo
    /// engine (`TodoStore`) refresh inside the same `gated(.vitrinka)` pass,
    /// so an off-mesh Mac backs off once and every vitrinka surface folds
    /// together. Hiding the listener section skips its requests, not the
    /// todos'.
    private func refreshVitrinka() async {
        let wantListeners = isSectionVisible("vitrinka")
        if !wantListeners { vitrinkaListening = [] }
        // A half-open trial spends ONE request (`probe`) before the fan-out
        // is allowed back — without it the default probe reports success,
        // clears the strike ladder, and a still-dead host restarts at the
        // gentle 2-minute step every round.
        await gated(.vitrinka, probe: { await VitrinkaClient.shared.probe() }) {
            // Atomic from the rails' point of view: nothing is published until
            // BOTH halves answered, and any failure folds both — one hide,
            // one breaker, never a listener rail showing a stale success
            // beside a hidden todo rail.
            var listening: [VitrinkaListening] = []
            if wantListeners {
                switch await VitrinkaClient.shared.listening() {
                case let .failed(failure):
                    vitrinkaListening = []
                    TodoStore.shared.markUnreachable()
                    return failure
                case let .value(value):
                    listening = value
                }
            }
            if let failure = await TodoStore.shared.refresh(using: VitrinkaClient.shared) {
                vitrinkaListening = []
                return failure
            }
            vitrinkaListening = listening
            return nil
        }
    }

    // MARK: - Devbox (one ws-v2 snapshot over ssh)

    /// Workspace identity, units, fleet cpu/mem and public hosts all arrive in
    /// one ssh process. A repo-local `ws ls --json` pass adds Mac-only app
    /// ports and sync paths without touching sshd.
    ///
    /// Deliberately independent of the other sections: the box being asleep or
    /// this Mac being off-network empties devbox and leaves GitHub/Sentry alone.
    ///
    /// This is the only poll that talks to sshd, so it is the one that got
    /// this Mac banned: a failing poll is an authentication attempt repeated
    /// every 90 seconds, forever. Its breaker matters more than the rest —
    /// and its one-request way back in stays `DevboxClient.status()`, the
    /// cheap probe, never this heavier call.
    private func refreshDevbox() async {
        guard isSectionVisible("devbox") else {
            devboxWorkspaces = []
            devboxProjects = []
            devboxSummary = nil
            devboxFetchedAt = nil
            return
        }
        await gated(.devbox, probe: {
            // The cheap one-request way back in for a half-open breaker —
            // `status()`, never the docker-stats-heavy hub call. A successful
            // trial then proceeds to `work` like every other gated target.
            if case let .failed(failure) = await DevboxClient.shared.status() {
                return failure
            }
            return nil
        }) {
            switch await DevboxClient.shared.hub() {
            case let .failed(failure):
                devboxWorkspaces = []
                devboxProjects = []
                devboxSummary = nil
                // A hidden rail must not keep a stale "as of" for its return.
                devboxFetchedAt = nil
                return failure
            case let .value(hub):
                // The overview lists hot AND parked identities (parking
                // contract, 2026-09-02): a parked workspace still holds its
                // slot and ports and is one `up` from hot, so it stays on the
                // rail as a parked card — vanishing is what a reaped
                // workspace does. Anything the box calls neither is not a
                // slot and is not shown.
                devboxWorkspaces = hub.workspaces.filter { $0.isHot || $0.isParked }
                devboxProjects = hub.projects
                devboxSummary = hub.summary
                devboxFetchedAt = hub.generated
                notifyDevboxPressure(hub.summary)
                return nil
            }
        }
    }

    /// The sweep parked something because the box was short, not because a
    /// workspace went quiet: parked rose while memory PSI was non-zero. A
    /// stale park at PSI 0 is routine housekeeping and stays silent. Only a
    /// rise counts — a revive that lowers the count is the user's own doing.
    private func notifyDevboxPressure(_ summary: DevboxOverviewSummary) {
        defer { previousDevboxParked = summary.parked }
        guard let previous = previousDevboxParked,
              summary.parked > previous,
              summary.pressureSome > 0
        else { return }
        let parked = summary.parked - previous
        let psi = String(format: "%.1f", summary.pressureSome)
        let free = String(format: "%.0fG", summary.availableGB)
        Notifier.send(
            title: "devbox — parked \(parked) under memory pressure",
            body: "\(summary.running) hot of \(summary.hotCeiling) · PSI some \(psi) · \(free) free / \(summary.floorGB)G floor",
            url: nil
        )
    }

    /// A card action (park / hold / up) just changed the box; the next
    /// scheduled poll is up to 90 s away. Same gated path, so a box that has
    /// gone away is still never hammered.
    func refreshDevboxNow() async {
        await refreshDevbox()
    }

    #if DEBUG
        /// Targeted native-UI verification hook. It deliberately calls the same
        /// gated production path; only the scheduling shortcut is Debug-only.
        func debugRefreshDevbox() async {
            await refreshDevbox()
        }
    #endif

    // MARK: - Sections, projects & config

    var projects: [ProjectSpec] {
        preferences.projects
    }

    func isSectionVisible(_ key: String) -> Bool {
        !preferences.hiddenSections.contains(key)
    }

    /// Configured VPSes — `/ssh` resolves its argument against these.
    var servers: [Preferences.NamedRef] {
        preferences.servers
    }

    /// Server display names in configured order — the services rail groups by
    /// these, so an unconfigured host never invents a heading of its own.
    var serverNames: [String] {
        preferences.servers.map(\.name)
    }

    /// Right-rail collapse state (decision D11). Persisted, so a folded rail
    /// stays folded across relaunches.
    func isRailCollapsed(_ key: String) -> Bool {
        preferences.collapsedRails.contains(key)
    }

    func setRail(_ key: String, collapsed: Bool) {
        preferences.collapsedRails.removeAll { $0 == key }
        if collapsed { preferences.collapsedRails.append(key) }
        preferences.save()
    }

    /// The vitrinka project the panel's own writers file into (a promoted
    /// note, an expiry-radar reminder); nil = unset, and they refuse.
    var todoProject: String? {
        preferences.todoProject
    }

    /// Settings ▸ General ▸ Todos.
    func setTodoProject(_ slug: String?) {
        preferences.todoProject = slug
        preferences.save()
    }

    var codeEditor: String? {
        preferences.codeEditor
    }

    /// `/editor <name>` and the Settings picker; nil = autodetect.
    func setCodeEditor(_ id: String?) {
        preferences.codeEditor = id
        preferences.save()
    }

    func setSection(_ key: String, visible: Bool) {
        preferences.hiddenSections.removeAll { $0 == key }
        if !visible { preferences.hiddenSections.append(key) }
        preferences.save()
    }

    func isAlertLaneVisible(_ lane: String) -> Bool {
        preferences.visibleAlertLanes.contains(lane)
    }

    func setAlertLane(_ lane: String, visible: Bool) {
        preferences.visibleAlertLanes.removeAll { $0 == lane }
        if visible { preferences.visibleAlertLanes.append(lane) }
        preferences.save()
        onChange?()
    }

    /// Query → project, matched on key/title prefix ("fix" → ExampleApp).
    func matchProject(_ query: String) -> ProjectSpec? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return nil }
        return preferences.projects.first {
            $0.key.lowercased().hasPrefix(q) || $0.title.lowercased().hasPrefix(q)
        }
    }

    // MARK: - Sentry settings

    /// The Sentry token lives in the login keychain (service `pultik-sentry`).
    /// A token found in settings.json — where it sat in plaintext before the
    /// integrations hub — is migrated in and blanked on first read, so old
    /// installs upgrade themselves without losing access mid-poll.
    var sentryToken: String? {
        if let token = Keychain.read(service: "pultik-sentry", account: "token") {
            return token
        }
        guard let legacy = preferences.sentryToken else { return nil }
        if let failure = Keychain.write(service: "pultik-sentry", account: "token", value: legacy) {
            NSLog("pultik: sentry token migration failed (%@) — keeping settings.json copy", failure)
            return legacy
        }
        preferences.sentryToken = nil
        preferences.save()
        NSLog("pultik: sentry token migrated from settings.json to the keychain")
        return legacy
    }

    /// Read-only view for the Integrations pane (preferences itself stays
    /// private — every mutation goes through a store method).
    var sentryProjects: [String] {
        preferences.sentryProjects
    }

    /// Returns nil on success, or the keychain's complaint — the Settings
    /// editor shows it rather than reporting a token as saved that is not.
    @discardableResult
    func setSentryToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure: String? = if let trimmed, !trimmed.isEmpty {
            Keychain.write(service: "pultik-sentry", account: "token", value: trimmed)
        } else {
            Keychain.delete(service: "pultik-sentry", account: "token")
        }
        if let failure {
            // A failed write leaves the keychain WITHOUT the new token, so the
            // legacy plaintext copy may be the only credential left — blanking
            // it here would log the user out of Sentry with nothing to fall
            // back on. Same for a failed delete: the old keychain value is
            // still live, so the caller has not actually been cleared.
            NSLog("pultik: sentry token keychain write failed: %@", failure)
        } else if preferences.sentryToken != nil {
            // Only once the keychain really holds the truth may the legacy
            // copy go — it must not linger to shadow the keychain value.
            preferences.sentryToken = nil
            preferences.save()
        }
        lastSentryRefresh = nil
        Task { await refresh() }
        return failure.map { "keychain refused the token: \($0)" }
    }

    // MARK: - eve settings

    var eveToken: String? {
        preferences.eveToken
    }

    /// nil on success, matching `setSentryToken` — settings.json writes have
    /// no failure channel of their own, so this one is always nil today.
    @discardableResult
    func setEveToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        preferences.eveToken = (trimmed?.isEmpty ?? true) ? nil : trimmed
        preferences.save()
        Task { await refresh() }
        return nil
    }

    // MARK: - Pin management & discovery

    /// Whether `slug` is a shape GitHub can actually resolve.
    ///
    /// Guarding this matters more than it looks: a pin that 404s does so on
    /// EVERY refresh, forever, and when it is the only pin the all-failed
    /// branch above reads a permanent 404 as "GitHub is down" and trips the
    /// probe breaker. Note `split` omits empty subsequences by default, so
    /// the obvious two-part check waves through `/owner/repo` and
    /// `owner//repo` — both of which build `…/repos//owner/repo`.
    nonisolated static func isRepoSlug(_ slug: String) -> Bool {
        let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let owner = parts[0], name = parts[1]
        // GitHub: owner is alphanumeric-or-hyphen, no hyphen at either end,
        // ≤39 chars; a repo name adds "_" and "." and stops at 100.
        guard !owner.isEmpty, owner.count <= 39,
              !owner.hasPrefix("-"), !owner.hasSuffix("-"),
              owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return false }
        guard !name.isEmpty, name.count <= 100, name != ".", name != "..",
              name.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
              })
        else { return false }
        return true
    }

    /// The single writer of `pinned`, so the slug rule is enforced here rather
    /// than trusted to each caller. Rejection is a silent no-op, matching the
    /// empty/duplicate guards — callers that can show a message check first.
    func pin(_ slug: String) {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isRepoSlug(trimmed), !pinned.contains(trimmed) else { return }
        pinned.append(trimmed)
        Task { await refresh() }
    }

    func unpin(_ slug: String) {
        pinned.removeAll { $0 == slug }
        repos.removeAll { $0.slug == slug }
    }

    func loadSuggestions() async {
        guard !gate.isPaused(.github) else { return }
        do {
            let discovered = try await client.discoverRepos()
            suggestions = discovered.filter { !pinned.contains($0) }
        } catch {
            globalError = error.localizedDescription
        }
    }

    // MARK: - Run actions

    func rerun(repo: String, runId: Int, failedJobsOnly: Bool) {
        Task {
            do {
                try await client.rerun(repo: repo, runId: runId, failedJobsOnly: failedJobsOnly)
                await refresh()
            } catch {
                globalError = error.localizedDescription
            }
        }
    }

    func cancel(repo: String, runId: Int) {
        Task {
            do {
                try await client.cancel(repo: repo, runId: runId)
                await refresh()
            } catch {
                globalError = error.localizedDescription
            }
        }
    }
}
