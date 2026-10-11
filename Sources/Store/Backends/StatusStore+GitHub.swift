import Foundation

extension StatusStore {
    /// The GitHub lane. No pinned repos skips GitHub only — every other lane
    /// (firing notifications included) still polls.
    func refreshGitHubLane() async {
        let slugs = pinned
        if slugs.isEmpty {
            repos = []
            lastRefresh = Date()
            NowStore.shared.forget(.githubStalePRs)
        } else {
            await refreshGitHub(slugs)
        }
    }

    func refreshGitHub(_ slugs: [String]) async {
        // PRs, checks, reviews and deployments for every repo come from one
        // GraphQL read per chunk. Workflow runs stay REST: missing repos
        // first, then one repo per tick with a five-minute floor each.
        do { try await ensurePRIndex() }
        catch { NSLog("pultik: PR cache identity unavailable: %@", error.localizedDescription) }
        await gated(.github, probe: { [client] in await client.probeHealth() }) {
            // An archive page failing (a removed repo's 404) must not hold back
            // the estate; the estate read alone decides the breaker.
            await refreshPRArchiveIfNeeded()
            let identity = prIndexIdentity
            let scope = searchableRepos
            let estate: [String: GitHubEstate.Repo]
            do { estate = try await client.estate(repos: scope) }
            catch is CancellationError { return nil }
            catch {
                NSLog("pultik: GitHub estate failed: %@", error.localizedDescription)
                globalError = error.localizedDescription
                recordStalePRNeeds(nil, estate: [:], identity: identity)
                return ProbeFailure.tripping(error)
            }

            var selected = slugs.filter { githubPolledAt[$0] == nil }
            if selected.isEmpty {
                for _ in slugs.indices {
                    let slug = slugs[githubPollCursor % slugs.count]
                    githubPollCursor = (githubPollCursor + 1) % slugs.count
                    if Date().timeIntervalSince(githubPolledAt[slug] ?? .distantPast) >= 300 {
                        selected = [slug]
                        break
                    }
                }
            }
            for slug in selected { githubPolledAt[slug] = Date() }
            let runs = await withTaskGroup(of: (String, Result<[WorkflowRun], Error>).self) { group in
                var remaining = selected.makeIterator()
                // Bound simultaneous response decoding across a large estate.
                for _ in 0..<4 {
                    guard let slug = remaining.next() else { break }
                    group.addTask { [client] in await Self.fetchRuns(slug: slug, client: client) }
                }
                var collected: [String: Result<[WorkflowRun], Error>] = [:]
                for await (slug, result) in group {
                    collected[slug] = result
                    if let slug = remaining.next() {
                        group.addTask { [client] in await Self.fetchRuns(slug: slug, client: client) }
                    }
                }
                return collected
            }
            if let current = try? await client.cacheIdentity(), current != identity || identity != prIndexIdentity {
                do { try await ensurePRIndex() }
                catch { NSLog("pultik: PR cache identity changed during refresh: %@", error.localizedDescription) }
                return nil
            }

            // One repo failing keeps its last snapshot and shows its error;
            // only the estate read failing as a whole opens the breaker.
            var merged = Dictionary(uniqueKeysWithValues: repos.map { ($0.slug, $0) })
            var answered = false
            for slug in slugs {
                var status = merged[slug] ?? RepoStatus(slug: slug)
                var errors: [String] = []
                if let repo = estate[slug] {
                    if let error = repo.error { errors.append(error) } else {
                        status.prs = repo.prs
                        status.deploys = repo.deploys
                        answered = true
                    }
                }
                switch runs[slug] {
                case .success(let fetched): status.runs = fetched; answered = true
                case .failure(let error): errors.append(error.localizedDescription)
                case nil: break
                }
                status.error = errors.first
                if let error = status.error { NSLog("pultik: %@ error: %@", slug, error) }
                merged[slug] = status
            }
            repos = slugs.compactMap { merged[$0] }
            recordStalePRNeeds(repos, estate: estate, identity: identity)
            if prIndexIdentity != nil {
                let now = Date()
                for (slug, repo) in estate where repo.error == nil {
                    prIndex.rememberRecent(repo: slug, hits: repo.recent, limit: GitHubEstate.recentLimit, now: now)
                    prIndex.ingest(repo.prs.map { ArchivedPR(pr: $0.pr, repoSlug: slug, fetchedAt: now) }, now: now)
                }
                persistPRIndex()
                if searchQuery.count >= 2 { showLocalPRs(query: searchQuery, repos: searchableRepos) }
            }
            notifyTransitions(repos)
            // Stamped HERE, not once per poll: while GitHub is paused the
            // inbox is not refreshing, and a footer reading "just now" over
            // half-hour-old runs would be a lie the pause badge can't undo.
            if answered {
                lastRefresh = Date()
                if let identity { recordGitHubSnapshot(identity: identity, slugs: slugs) }
            }
            onChange?()
            globalError = !repos.isEmpty && repos.allSatisfy { $0.error != nil } ? repos.first?.error : nil
            return nil
        }
    }

    func refreshPRArchiveIfNeeded() async {
        if let at = archiveAttemptedAt, Date().timeIntervalSince(at) < 30 { return }
        let scope = searchableRepos
        guard !scope.isEmpty else { return }
        archiveAttemptedAt = Date() // failed pages back off too
        do {
            try await ensurePRIndex()
            let identity = prIndexIdentity
            for _ in scope.indices {
                let repo = scope[archiveCursor % scope.count]
                archiveCursor = (archiveCursor + 1) % scope.count
                guard let page = prIndex.archivePage(repo: repo, now: Date()) else { continue }
                let hits = try await client.archivePage(repo: repo, page: page)
                guard identity == prIndexIdentity, try await client.cacheIdentity() == identity else { return }
                prIndex.rememberPage(repo: repo, page: page, hits: hits, now: Date())
                persistPRIndex()
                if searchQuery.count >= 2 { showLocalPRs(query: searchQuery, repos: searchableRepos) }
                return
            }
        } catch {
            NSLog("pultik: PR archive refresh failed: %@", error.localizedDescription)
        }
    }

    private nonisolated static func fetchRuns(
        slug: String, client: GitHubClient
    ) async -> (String, Result<[WorkflowRun], Error>) {
        do { return (slug, .success(Self.displayRuns(try await client.workflowRuns(repo: slug)))) }
        catch { return (slug, .failure(error)) }
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

    func notifyTransitions(_ statuses: [RepoStatus]) {
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
