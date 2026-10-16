import Foundation

/// Live CI status from the BuildServer mesh (stay in Pultík D7): Prometheus'
/// `ci_runner_job_info` joined to the watched runs by the run id in its
/// `run_url`, `ci_jobs_queued` per lane, and each host's Semafor admission
/// head — the lane that places next there — while something of ours still
/// waits.
struct MeshCIStatus: CIStatusSource {
    let metrics: MetricsClient
    /// Every host's placing lane, each Semafor read behind its own breaker
    /// by the caller.
    let head: @Sendable () async -> Set<String>

    func snapshot(for runs: Set<CIRunRef>) async throws -> CIStatusSnapshot {
        let ids = Set(runs.map(\.runID))
        let live = try await metrics.liveJobs()
        var snapshot = CIStatusSnapshot(queued: live.queued)
        for job in live.jobs {
            guard let run = CIWatch.runID(in: job.runURL), ids.contains(run) else { continue }
            snapshot.jobs[run, default: []].append(CILiveJob(name: job.jobName, lane: job.lane, since: job.since))
        }
        if live.queued.values.contains(where: { $0 > 0 }) {
            snapshot.next = await head()
        }
        return snapshot
    }
}
