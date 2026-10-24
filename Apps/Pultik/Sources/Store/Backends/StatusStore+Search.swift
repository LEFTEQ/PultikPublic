import Foundation

extension StatusStore {
    // MARK: - PR search (the archive)


    #if DEBUG
    func githubRequestCounts() async
        -> (network: Int, shared: Int, lookups: Int, searches: Int, details: Int, files: Int, ciRuns: Int, ciLogs: Int,
            releases: Int, batches: Int) {
        (await client.networkRequests, await client.sharedRequests,
         await client.prLookupRequests, await client.prSearchRequests,
         await client.prDetailRequests, await client.prFilesRequests,
         await client.ciDetailRequests, await client.ciLogRequests, await client.releaseRequests,
         await client.prBatchRequests)
    }
    #endif

    func ensurePRIndex() async throws {
        let identity = try await client.cacheIdentity()
        guard prIndexIdentity != identity else { return }
        if prIndexLoad?.identity != identity {
            if prIndexIdentity != nil {
                searchTask?.cancel()
                searchScope = ""
                repos = []
            }
            prIndex = GitHubPRIndex()
            searchResults = []
            searchFetchedAt = nil
            prIndexIdentity = nil
            let disk = prIndexDisk
            prIndexLoad = (identity, Task { await disk.load(identity: identity) })
        }
        guard let load = prIndexLoad else { return }
        let index = await load.task.value
        guard prIndexLoad?.identity == identity else { return }
        prIndex = index
        prIndexIdentity = identity
        prIndexLoad = nil
        if searchQuery.count >= 2 { showLocalPRs(query: searchQuery, repos: searchableRepos) }
        if searchScope.isEmpty, searchQuery.count >= 2 { search(searchQuery) }
    }

    func persistPRIndex() {
        guard let identity = prIndexIdentity else { return }
        prIndexRevision += 1
        let revision = prIndexRevision
        let index = prIndex
        let disk = prIndexDisk
        Task { await disk.save(index, identity: identity, revision: revision) }
    }

    @discardableResult
    func showLocalPRs(query: String, repos: [String]) -> GitHubPRIndex.Answer {
        let start = DispatchTime.now().uptimeNanoseconds
        let answer = prIndex.answer(query: query, repos: repos, now: Date())
        searchResults = answer.hits
        searchFetchedAt = answer.fetchedAt
        searchIsPartial = !answer.isFresh
        localSearchMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return answer
    }

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
        return searchResults.filter { prIndex.contains(repo: $0.repoSlug, in: searchableRepos)
            && !onDashboard.contains($0.id.lowercased()) }
    }

    /// Answer locally before debounce or breaker admission. Fresh complete
    /// queries spend zero calls; remote work fills coverage without blanking rows.
    func search(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sentry rides the same keystrokes but keeps its own task and state —
        // GitHub being slow or erroring must not delay or blank prod hits.
        searchSentry(query)
        let repos = searchableRepos
        let scope = GitHubPRIndex.key(query: query, repos: repos)
        guard query != searchQuery || scope != searchScope else { return }
        searchQuery = query
        searchScope = scope
        searchTask?.cancel()
        searchError = nil
        guard query.count >= 2 else {
            searchResults = []
            searchFetchedAt = nil
            searchIsPartial = false
            isSearching = false
            return
        }
        let cached = showLocalPRs(query: query, repos: repos)
        guard !cached.isFresh else { isSearching = false; return }
        guard !gate.isPaused(.github) else {
            searchError = "GitHub paused; saved results remain available"
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [client] in
            defer { if !Task.isCancelled, scope == searchScope { isSearching = false } }
            do {
                try await Task.sleep(for: .milliseconds(350))
                try await ensurePRIndex()
                guard !Task.isCancelled, scope == searchScope else { return }
                let local = showLocalPRs(query: query, repos: repos)
                if local.isFresh { isSearching = false; return }
                let identity = prIndexIdentity
                let found: GitHubPRSearchResult
                if let number = Self.typedNumber(in: query) {
                    let missing = prIndex.reposNeedingLookup(number: number, repos: repos, now: Date())
                    let lookup = try await client.lookupPullRequests(number: number, repos: missing)
                    guard !Task.isCancelled, scope == searchScope, identity == prIndexIdentity,
                          try await client.cacheIdentity() == identity else { return }
                    prIndex.rememberLookup(number: number, repos: lookup.confirmedRepos, hits: lookup.hits, now: Date())
                    if let failure = lookup.failure { gate.failed(.github, failure) }
                    let combined = prIndex.answer(query: query, repos: repos, now: Date()).hits
                    found = .init(hits: combined, complete: lookup.warning == nil, warning: lookup.warning)
                } else {
                    found = try await client.searchPullRequests(terms: query, repos: repos)
                }
                guard !Task.isCancelled, scope == searchScope, identity == prIndexIdentity,
                      try await client.cacheIdentity() == identity else { return }
                prIndex.remember(query: query, repos: repos, hits: found.hits, complete: found.complete, now: Date())
                showLocalPRs(query: query, repos: repos)
                searchError = found.warning
                persistPRIndex()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A palette failure is a host failure like any other — feed
                // the breaker, or a refusal first seen here never opens it
                // and every further keystroke keeps knocking.
                if let failure = ProbeFailure.tripping(error) { gate.failed(.github, failure) }
                guard scope == searchScope else { return }
                searchError = error.localizedDescription
            }
        }
    }

    /// "520" and "#520" mean item number 520; anything else is full text.
    static func typedNumber(in query: String) -> Int? {
        GitHubPRIndex.number(in: query)
    }

    // MARK: - Sentry search (palette full text)


    /// Search hits that aren't already on the prod strip above — same contract
    /// as `searchMatches`: the section shows what the dashboard can't.
    var sentryMatches: [ProdIssue] {
        let onStrip = Set(prodIssues.map(\.id))
        return sentryResults.filter { !onStrip.contains($0.id) }
    }

    /// Debounced org-wide Sentry search — resolves short ids ("EXAMPLEAPP-API-86")
    /// and full text alike. Same cancel/stale-guard contract as `search(_:)`.
    func searchSentry(_ query: String) {
        guard query != sentryQuery else { return }
        sentryQuery = query
        sentrySearchTask?.cancel()

        // A paused breaker holds for typing too: a keystroke-driven search is
        // the fastest way to turn one refused request into fifty.
        guard query.count >= 2, isSectionVisible("prod"), !gate.isPaused(.sentry),
              RuntimeConfig.current.sentry != nil else {
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

    static let issueCacheLimit = 20

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

        guard query.count >= 2 else {
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
        guard !gate.isPaused(.github) else {
            issueResults = []
            issueSearchError = "GitHub paused; cached queries remain available"
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
                if let failure = ProbeFailure.tripping(error) { gate.failed(.github, failure) }
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
    static func issueCacheKey(repos: [String], query: String) -> String {
        repos.joined(separator: ",").lowercased() + "|" + query.lowercased()
    }

    func cachedIssues(_ query: String) -> [ArchivedIssue]? {
        // A READ is correctly keyed by the scope in force right now.
        let key = Self.issueCacheKey(repos: searchableRepos, query: query)
        guard let hits = issueCache[key] else { return nil }
        // A hit is a use: move it to the young end so it survives eviction.
        issueCacheOrder.removeAll { $0 == key }
        issueCacheOrder.append(key)
        return hits
    }

    func remember(_ key: String, _ found: [ArchivedIssue]) {
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
    func refreshIssuesIfStale() async {
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
}
