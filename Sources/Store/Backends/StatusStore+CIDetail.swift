import Foundation
import Observation

/// One Actions run as the CI module reads it.
struct CIRunRef: Hashable, Sendable {
    let repo: String
    let runID: Int
}

extension StatusStore {
    /// The CI run detail reads (WP6), through the query repository: explicit
    /// selection only (D8), keyed by the GitHub credential digest, never polled.
    enum CIDetailResources {
        /// The run and its jobs move while it runs; fresh for 15 s.
        static let run = QueryResource<GitHubCIRun.Detail>(
            name: "github.ci.run", staleAfter: 15, persists: false, keep: 24)
        /// A finished job's log never changes: served at any age.
        static let log = QueryResource<GitHubCIRun.LogTail>(
            name: "github.ci.log", staleAfter: .infinity, persists: false, keep: 12)
        /// Semafor's 7 d repo health; no credential, the mesh is the identity.
        static let health = QueryResource<[SemaforRepoHealth]>(
            name: "semafor.repos.health", staleAfter: 300, persists: false, keep: 1)
    }

    /// The pinned repo whose polled runs hold `runID`.
    func ciRunRef(runID: Int) -> CIRunRef? {
        repos.first { $0.runs.contains { $0.id == runID } }.map { CIRunRef(repo: $0.slug, runID: runID) }
    }

    func cachedCIRun(_ ref: CIRunRef) -> GitHubCIRun.Detail? {
        guard let identity = prIndexIdentity else { return nil }
        return QueryRepository.shared.cached(GitHubCIRun.Detail.self, key: ciRunKey(ref, identity: identity))?.value
    }

    func ciRun(_ ref: CIRunRef, maxAge: TimeInterval = CIDetailResources.run.staleAfter) async throws
        -> GitHubCIRun.Detail {
        let identity = try await client.cacheIdentity()
        return try await QueryRepository.shared.load(CIDetailResources.run, key: ciRunKey(ref, identity: identity),
                                                     maxAge: maxAge) { [client] in
            try await client.ciRunDetail(repo: ref.repo, runID: ref.runID, identity: identity)
        }
    }

    /// A job's log tail. A completed job's is final and kept; a running job's
    /// is still being written, so it lives under its own key and never
    /// stands in for the final one.
    func ciLogTail(_ ref: CIRunRef, job: GitHubCIRun.Job) async throws -> GitHubCIRun.LogTail {
        let identity = try await client.cacheIdentity()
        let final = job.status == "completed"
        let key = QueryKey(resource: CIDetailResources.log.name, identity: identity,
                           scope: "\(ref.repo)/job/\(job.id)/\(final ? "final" : "live")")
        return try await QueryRepository.shared.load(CIDetailResources.log, key: key,
                                                     maxAge: final ? .infinity : 0) { [client] in
            try await client.ciJobLogTail(repo: ref.repo, jobID: job.id, identity: identity)
        }
    }

    func semaforRepoHealth() async throws -> [SemaforRepoHealth] {
        try await QueryRepository.shared.load(CIDetailResources.health,
                                              key: QueryKey(resource: CIDetailResources.health.name, identity: "mesh"),
                                              maxAge: CIDetailResources.health.staleAfter) {
            try await SemaforClient.shared.repoHealth()
        }
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
    func rerun(_ ref: CIRunRef, shown: GitHubCIRun.Run?, store: StatusStore) {
        guard outcomes[ref.runID] != .checking else { return }
        outcomes[ref.runID] = .checking
        Task {
            defer { generations[ref.runID, default: 0] += 1 }
            do {
                let identity = try await store.client.cacheIdentity()
                let attempt: GitHubCIRun.Run
                if let shown { attempt = shown } else { attempt = try await store.ciRun(ref).run }
                let verdict = try await store.client.rerunFailedIfStill(repo: ref.repo, shown: attempt, identity: identity)
                switch verdict {
                case .rerun: outcomes[ref.runID] = .requested
                case .running: outcomes[ref.runID] = .skipped("already running again")
                case let .newerAttempt(attempt): outcomes[ref.runID] = .skipped("attempt \(attempt) exists")
                case let .notFailed(conclusion): outcomes[ref.runID] = .skipped("now \(conclusion ?? "unknown")")
                }
                store.ciRunChanged(ref)
            } catch {
                NSLog("pultik: re-run %@ %d failed: %@", ref.repo, ref.runID, error.localizedDescription)
                outcomes[ref.runID] = .failed(error.localizedDescription)
            }
        }
    }
}
