import Foundation
import Observation

extension StatusStore {
    /// The CI run detail reads (WP6), through the query repository: explicit
    /// selection only (D8), keyed by the GitHub credential digest, never polled.
    enum CIDetailResources {
        /// The run and its jobs move while it runs; fresh for 15 s.
        static let run = QueryResource<CIRunDetail>(
            name: "ci.run", staleAfter: 15, persists: false, keep: 24)
        /// A finished job's log never changes: served at any age.
        static let log = QueryResource<LogTail>(
            name: "ci.log", staleAfter: .infinity, persists: false, keep: 12)
        /// A run's job graph (stay in Pultík D11): its workflow file at the run's
        /// head never changes, so it is kept across relaunches.
        static let graph = QueryResource<WorkflowGraph>(name: "ci.graph", staleAfter: .infinity, keep: 60)
        /// A host Semafor's 7 d repo health; no credential, the Semafor is
        /// the identity (one per host).
        static let health = QueryResource<[SemaforRepoHealth]>(
            name: "semafor.repos.health", staleAfter: 300, persists: false, keep: 4)
    }

    /// The pinned repo whose polled runs hold `runID`.
    func ciRunRef(runID: Int) -> CIRunRef? {
        repos.first { $0.runs.contains { $0.id == runID } }.map { CIRunRef(repo: $0.slug, runID: runID) }
    }

    func cachedCIRun(_ ref: CIRunRef) -> CIRunDetail? {
        guard let identity = prIndexIdentity else { return nil }
        return QueryRepository.shared.cached(CIRunDetail.self, key: ciRunKey(ref, identity: identity))?.value
    }

    func ciRun(_ ref: CIRunRef, maxAge: TimeInterval = CIDetailResources.run.staleAfter) async throws
        -> CIRunDetail {
        let host = ciHost
        let identity = try await host.identity()
        return try await QueryRepository.shared.load(CIDetailResources.run, key: ciRunKey(ref, identity: identity),
                                                     maxAge: maxAge) {
            try await host.run(ref, identity: identity)
        }
    }

    /// A job's log tail. A completed job's is final and kept; a running job's
    /// is still being written, so it lives under its own key and never
    /// stands in for the final one.
    func ciLogTail(_ ref: CIRunRef, job: CIRunJob) async throws -> LogTail {
        let host = ciHost
        let identity = try await host.identity()
        let final = job.status == .completed
        let key = QueryKey(resource: CIDetailResources.log.name, identity: identity,
                           scope: "\(ref.repo)/job/\(job.id)/\(final ? "final" : "live")")
        return try await QueryRepository.shared.load(CIDetailResources.log, key: key,
                                                     maxAge: final ? .infinity : 0) {
            try await host.logTail(ref, job: job, identity: identity)
        }
    }

    /// The run's `needs:` graph from the git mirror (D10, D11); nil without a
    /// workflow path or when the mirror cannot read it — the card falls back
    /// to timing waves.
    func workflowGraph(_ run: CIRun) async -> WorkflowGraph? {
        guard let path = run.workflowPath, !path.isEmpty else { return nil }
        let host = codeHost
        do {
            let identity = try await host.identity()
            let key = QueryKey(resource: CIDetailResources.graph.name, identity: identity,
                               scope: "\(run.ref.repo)@\(run.headSHA):\(path)")
            return try await QueryRepository.shared.load(CIDetailResources.graph, key: key, maxAge: .infinity) {
                let yaml = try await GitMirror.shared.file(run.ref.repo, path: path, at: run.headSHA,
                                                           remote: host.remoteURL(repo: run.ref.repo),
                                                           password: try await host.gitPassword(identity: identity))
                return WorkflowGraph.parse(yaml)
            }
        } catch is CancellationError {
            return nil
        } catch {
            NSLog("pultik: workflow graph of %@ unavailable: %@", run.ref.key, error.localizedDescription)
            return nil
        }
    }

    /// The repo's job outcomes from the Semafor of the host `run` ran on —
    /// that Semafor alone saw its jobs. nil when the host is not settled.
    func semaforRepoHealth(of run: CIRunDetail) async throws -> SemaforRepoHealth? {
        let repo = run.run.ref.repo
        guard let host = laneBoard.host(ofRunners: run.jobs.compactMap(\.runnerName), repo: repo),
              let base = semaforBase(forHost: host) else { return nil }
        let rows = try await QueryRepository.shared.load(
            CIDetailResources.health,
            key: QueryKey(resource: CIDetailResources.health.name, identity: base.absoluteString),
            maxAge: CIDetailResources.health.staleAfter
        ) {
            try await SemaforClient.shared.repoHealth(at: base)
        }
        return rows.first { $0.repo == repo }
    }

    /// After a re-run: the run's detail refetches, and the repo's runs poll on
    /// the lane's next tick instead of its five-minute floor.
    func ciRunChanged(_ ref: CIRunRef) {
        QueryRepository.shared.invalidate(resource: CIDetailResources.run.name)
        githubPolledAt[ref.repo] = nil
    }

    private func ciRunKey(_ ref: CIRunRef, identity: String) -> QueryKey {
        QueryKey(resource: CIDetailResources.run.name, identity: identity, scope: "\(ref.repo)/\(ref.runID)")
    }
}

/// ⌘R and the detail's Re-run failed verb share this one path (WP6): read
/// the run fresh, re-run its failed jobs only while it is still the failed
/// attempt on screen, and keep each run's outcome for the detail to say.
@MainActor
@Observable
final class CIRerunCenter {
    static let shared = CIRerunCenter()

    enum Outcome: Equatable {
        case checking
        case requested
        case skipped(String)
        case failed(String)
    }

    private(set) var outcomes: [Int: Outcome] = [:]
    /// Bumped when a re-run settles: the open detail reloads on it.
    private(set) var generations: [Int: Int] = [:]

    /// `shown` is the attempt the detail drew; nil = not read yet, so the
    /// run is read first and that attempt is the one judged.
    func rerun(_ ref: CIRunRef, shown: CIRun?, store: StatusStore) {
        guard outcomes[ref.runID] != .checking else { return }
        outcomes[ref.runID] = .checking
        Task { await perform(ref, shown: shown, store: store) }
    }

    /// The same re-run, awaited: bulk Re-run failed walks its runs one at a
    /// time inside the GitHub budget (bulk D6). A run already being checked
    /// answers `.checking` and is left to that call.
    func rerunNow(_ ref: CIRunRef, shown: CIRun?, store: StatusStore) async -> Outcome {
        guard outcomes[ref.runID] != .checking else { return .checking }
        outcomes[ref.runID] = .checking
        return await perform(ref, shown: shown, store: store)
    }

    @discardableResult
    private func perform(_ ref: CIRunRef, shown: CIRun?, store: StatusStore) async -> Outcome {
        defer { generations[ref.runID, default: 0] += 1 }
        let outcome: Outcome
        do {
            let host = store.ciHost
            let identity = try await host.identity()
            let attempt: CIRun
            if let shown { attempt = shown } else { attempt = try await store.ciRun(ref).run }
            let verdict = try await host.rerunFailedIfStill(ref, shown: attempt, identity: identity)
            switch verdict {
            case .rerun: outcome = .requested
            case .running: outcome = .skipped("already running again")
            case let .newerAttempt(attempt): outcome = .skipped("attempt \(attempt) exists")
            case let .notFailed(conclusion): outcome = .skipped("now \(conclusion?.rawValue ?? "unknown")")
            }
            outcomes[ref.runID] = outcome
            store.ciRunChanged(ref)
        } catch {
            NSLog("pultik: re-run %@ %d failed: %@", ref.repo, ref.runID, error.localizedDescription)
            outcome = .failed(error.localizedDescription)
            outcomes[ref.runID] = outcome
        }
        return outcome
    }
}
