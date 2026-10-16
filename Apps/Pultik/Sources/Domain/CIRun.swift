import Foundation

/// Where a CI run, job or step stands.
enum CIStatus: String, Codable, Sendable {
    case queued, running, waiting, pending, completed
}

/// How a finished CI run, job or step ended.
enum CIConclusion: String, Codable, Sendable {
    case success, failure, timedOut, startupFailure, cancelled, skipped, neutral, actionRequired, stale, unknown

    /// It broke — what turns a badge red and what Re-run failed re-runs.
    var failing: Bool { self == .failure || self == .timedOut || self == .startupFailure }
}

/// One CI run (a workflow run) as Pultík reads it.
struct CIRun: Codable, Sendable, Equatable {
    let ref: CIRunRef
    /// The workflow's name.
    let name: String?
    let displayTitle: String?
    let headBranch: String?
    let headSHA: String
    /// What started it: push, pull_request, schedule…
    let event: String
    let status: CIStatus
    let conclusion: CIConclusion?
    let attempt: Int
    let url: String
    let createdAt: Date
    let updatedAt: Date
    let startedAt: Date?
    /// The change requests this run is for, base repo only.
    let changeRequests: [Int]
    /// The workflow file the run came from (`.github/workflows/ci.yml`), when
    /// the host names it — the job graph's source.
    var workflowPath: String?

    var id: Int { ref.runID }
    var failed: Bool { conclusion?.failing == true }
}

struct CIRunJob: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let name: String
    let status: CIStatus
    let conclusion: CIConclusion?
    let startedAt: Date?
    let completedAt: Date?
    let url: String?
    let runnerName: String?
    let steps: [CIRunStep]

    /// Broke, or cancelled — a matrix's fail-fast cancels siblings of the
    /// job that broke.
    var failed: Bool { conclusion?.failing == true || conclusion == .cancelled }
    var duration: TimeInterval? { CIRunDetail.duration(startedAt, completedAt) }
    /// The step that failed: the first with a failing conclusion.
    var failingStep: CIRunStep? { steps.first { $0.conclusion?.failing == true } }
}

struct CIRunStep: Codable, Sendable, Equatable, Identifiable {
    let number: Int
    let name: String
    let status: CIStatus
    let conclusion: CIConclusion?
    let startedAt: Date?
    let completedAt: Date?

    var id: Int { number }
    var duration: TimeInterval? { CIRunDetail.duration(startedAt, completedAt) }
}

/// A run and its attempt's jobs.
struct CIRunDetail: Codable, Sendable, Equatable {
    let run: CIRun
    let jobs: [CIRunJob]
    /// The attempt has more than `jobLimit` jobs.
    var jobsTruncated = false

    static let jobLimit = 100

    /// The job to read first: one that failed, else one cancelled.
    var failingJob: CIRunJob? {
        jobs.first { $0.conclusion?.failing == true } ?? jobs.first(where: \.failed)
    }

    static func duration(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}

/// The lines of a job's log that explain it: around the last error, else
/// its last lines.
struct LogTail: Codable, Sendable, Equatable {
    struct Line: Codable, Sendable, Equatable {
        /// 1-based, in the whole job log.
        let number: Int
        let text: String
        let error: Bool
    }

    let lines: [Line]
    let totalLines: Int
    /// The window ends on an error line; false = the log's last lines.
    let anchored: Bool

    static let limit = 40
}

/// What ⌘R found when it read the run again.
enum RerunVerdict: Equatable, Sendable {
    /// Still the failed attempt on screen: re-run its failed jobs.
    case rerun
    /// It is running again (someone re-ran it, or it never finished).
    case running
    /// A later attempt exists; the screen is stale.
    case newerAttempt(Int)
    /// It no longer reads failed.
    case notFailed(CIConclusion?)

    static func judge(shown: CIRun, fresh: CIRun) -> RerunVerdict {
        if fresh.status != .completed { return .running }
        if fresh.attempt != shown.attempt { return .newerAttempt(fresh.attempt) }
        return fresh.failed ? .rerun : .notFailed(fresh.conclusion)
    }
}
