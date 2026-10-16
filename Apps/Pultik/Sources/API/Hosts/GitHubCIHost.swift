import Foundation

/// GitHub Actions as Pultík's first CI (stay in Pultík N2): runs, jobs,
/// steps and a job's log tail, read through `GitHubClient`. Live status does
/// not come from here — `CIStatusSource` watches our own CI and asks this
/// host only to confirm a transition.
struct GitHubCIHost: CIHost {
    let client: GitHubClient

    var host: HostKind { .github }

    func identity() async throws -> String {
        try await client.cacheIdentity()
    }

    func run(_ ref: CIRunRef, identity: String) async throws -> CIRunDetail {
        try await client.ciRunDetail(repo: ref.repo, runID: ref.runID, identity: identity)
    }

    func logTail(_ ref: CIRunRef, job: CIRunJob, identity: String) async throws -> LogTail {
        try await client.ciJobLogTail(repo: ref.repo, jobID: job.id, identity: identity)
    }

    func rerunFailedIfStill(_ ref: CIRunRef, shown: CIRun, identity: String) async throws -> RerunVerdict {
        try await client.rerunFailedIfStill(repo: ref.repo, shown: shown, identity: identity)
    }
}
