import Foundation

/// One CI run on a change request, as its badge draws it (stay in Pultík
/// D6): the worst job wins, the failing job is named inside, a running run
/// carries a live timer from its first job's start, and our CI's live read
/// adds the lane it runs on and that lane's queue. Twenty checks read as
/// three to five badges. A commit status (no run behind it) is a badge of
/// its own. Foundation-only: `Tests/RunBadgeTests.swift`.
struct RunBadge: Equatable, Identifiable, Sendable {
    typealias Outcome = ChangeRequest.Check.Outcome

    /// The run on the change request's host; nil for a commit status.
    let run: CIRunRef?
    /// The workflow's name, or the status context's.
    let name: String
    let outcome: Outcome
    /// Every job of the run, failing first.
    let jobs: [ChangeRequest.Check]
    /// The first failing job, named on the badge.
    let failingJob: String?
    let startedAt: Date?
    /// When the last job finished; nil while any runs.
    let completedAt: Date?
    var url: String?
    /// Our CI's live jobs for this run, when it watches it.
    var live: [CILiveJob] = []
    /// The backlog of the lane the run waits on (D7: a lane's queue, not a
    /// per-run position).
    var queuedOnLane: (lane: String, waiting: Int, next: Bool)?

    /// `run:<CIRunRef.key>` — the focus target ↵ pushes as a card.
    var id: String { run.map { "run:\($0.key)" } ?? "status:\(name)" }

    var passed: Int { jobs.filter { $0.outcome == .passed }.count }

    /// Running: time since the first job started; finished: the run's span.
    func elapsed(now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, (completedAt ?? now).timeIntervalSince(startedAt))
    }

    static func == (lhs: RunBadge, rhs: RunBadge) -> Bool {
        lhs.run == rhs.run && lhs.name == rhs.name && lhs.outcome == rhs.outcome && lhs.jobs == rhs.jobs
            && lhs.live == rhs.live && lhs.queuedOnLane?.lane == rhs.queuedOnLane?.lane
            && lhs.queuedOnLane?.waiting == rhs.queuedOnLane?.waiting
    }

    /// The checks of one change request → one badge per run, failing first,
    /// then running, passed, skipped; by name within an outcome.
    static func badges(_ checks: [ChangeRequest.Check], repo: String, host: HostKind = .github,
                       live: CIStatusSnapshot? = nil) -> [RunBadge] {
        var runs: [Int: [ChangeRequest.Check]] = [:]
        var order: [Int] = []
        var statuses: [ChangeRequest.Check] = []
        for check in checks {
            guard let runID = check.runID else {
                statuses.append(check)
                continue
            }
            if runs[runID] == nil { order.append(runID) }
            runs[runID, default: []].append(check)
        }
        var badges = order.compactMap { runID -> RunBadge? in
            guard let jobs = runs[runID] else { return nil }
            return badge(jobs, run: CIRunRef(host: host, repo: repo, runID: runID), live: live)
        }
        badges += statuses.map { badge([$0], run: nil, live: nil) }
        return badges.sorted { ($0.outcome, $0.name) < ($1.outcome, $1.name) }
    }

    private static func badge(_ checks: [ChangeRequest.Check], run: CIRunRef?, live: CIStatusSnapshot?) -> RunBadge {
        let jobs = checks.sorted { ($0.outcome, $0.name) < ($1.outcome, $1.name) }
        let outcome = jobs.map(\.outcome).min() ?? .skipped
        let starts = jobs.compactMap(\.startedAt)
        let running = jobs.contains { $0.outcome == .running }
        let ends = jobs.compactMap(\.completedAt)
        var badge = RunBadge(
            run: run, name: jobs.first?.workflow ?? jobs.first?.name ?? "checks", outcome: outcome, jobs: jobs,
            failingJob: jobs.first { $0.outcome == .failed }?.name, startedAt: starts.min(),
            completedAt: running ? nil : ends.max(), url: jobs.first { $0.outcome == .failed }?.url ?? jobs.first?.url)
        if let live, let run {
            badge.live = (live.jobs[run.runID] ?? []).sorted { $0.name < $1.name }
            // Running but not on a runner yet: the lane it waits on is the
            // one a sibling job runs on; without one there is nothing to say.
            if running, let lane = badge.live.first?.lane, let waiting = live.queued[lane], waiting > 0,
               badge.live.count < jobs.filter({ $0.outcome == .running }).count {
                badge.queuedOnLane = (lane, waiting, live.next.contains(lane))
            }
        }
        return badge
    }
}
