import Foundation

/// One Actions run read natively (copilot shell WP6, AC 10): the run, its
/// jobs and steps, and the tail of the failing job's log around its error —
/// "why did CI fail" in one step. Re-run failed (⌘R) revalidates the run
/// first and fires only while it is still the failed attempt on screen.
/// Foundation-only: the contract harness decodes it.
enum GitHubCIRun {
    struct Run: Codable, Sendable, Equatable {
        let id: Int
        let name: String?
        let displayTitle: String?
        let headBranch: String?
        let headSha: String
        let event: String
        /// queued · in_progress · completed · waiting · pending
        let status: String
        let conclusion: String?
        let runAttempt: Int
        let htmlUrl: String
        let createdAt: Date
        let updatedAt: Date
        let runStartedAt: Date?
        /// The PR numbers this run is for, base repo only.
        let pullRequests: [Int]

        var failed: Bool { Self.failing.contains(conclusion ?? "") }

        static let failing: Set<String> = ["failure", "timed_out", "startup_failure"]
    }

    struct Job: Codable, Sendable, Equatable, Identifiable {
        let id: Int
        let name: String
        let status: String
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
        let htmlUrl: String?
        let runnerName: String?
        let steps: [Step]

        var failed: Bool { Run.failing.contains(conclusion ?? "") || conclusion == "cancelled" }
        var duration: TimeInterval? { GitHubCIRun.duration(startedAt, completedAt) }
        /// The step that failed: the first with a failing conclusion.
        var failingStep: Step? { steps.first { Run.failing.contains($0.conclusion ?? "") } }
    }

    struct Step: Codable, Sendable, Equatable, Identifiable {
        let number: Int
        let name: String
        let status: String
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?

        var id: Int { number }
        var duration: TimeInterval? { GitHubCIRun.duration(startedAt, completedAt) }
    }

    /// What the detail holds: the run and its attempt's jobs.
    struct Detail: Codable, Sendable, Equatable {
        let run: Run
        let jobs: [Job]
        /// The attempt has more than `jobLimit` jobs.
        var jobsTruncated = false

        /// The job to read first: one that failed, else one cancelled — a
        /// matrix's fail-fast cancels siblings of the job that broke.
        var failingJob: Job? {
            jobs.first { Run.failing.contains($0.conclusion ?? "") } ?? jobs.first(where: \.failed)
        }
    }

    /// The lines around the failing job's last error.
    struct LogTail: Codable, Sendable, Equatable {
        struct Line: Codable, Sendable, Equatable {
            /// 1-based, in the whole job log.
            let number: Int
            let text: String
            let error: Bool
        }

        let lines: [Line]
        let totalLines: Int
        /// The window ends on an `##[error]` line; false = the log's last lines.
        let anchored: Bool
    }

    /// What ⌘R found when it looked again.
    enum Revalidation: Equatable {
        /// Still the failed attempt on screen: re-run its failed jobs.
        case rerun
        /// It is running again (someone re-ran it, or it never finished).
        case running
        /// A later attempt exists; the screen is stale.
        case newerAttempt(Int)
        /// It no longer reads failed.
        case notFailed(String?)

        static func judge(shown: Run, fresh: Run) -> Revalidation {
            if fresh.status != "completed" { return .running }
            if fresh.runAttempt != shown.runAttempt { return .newerAttempt(fresh.runAttempt) }
            return fresh.failed ? .rerun : .notFailed(fresh.conclusion)
        }
    }

    static let tailLimit = 40
    static let jobLimit = 100
    /// A streamed log keeps this many recent lines, each cut at `lineByteLimit`.
    static let windowLines = 4000
    static let lineByteLimit = 4096

    /// The recent lines of a streamed log and how many went before them,
    /// plus the window around the latest informative failure — kept even
    /// when thousands of cleanup lines after it roll out of the ring.
    struct LogWindow {
        private(set) var lines: [String] = []
        private(set) var total = 0
        private var start = 0
        private var candidate: [String] = []
        private var candidateStart = 0
        private var candidateAfter = 0

        mutating func append(_ line: String) {
            total += 1
            if candidateAfter > 0 {
                candidate.append(line)
                candidateAfter -= 1
            }
            // Substring checks first: most lines never reach the regex.
            let maybe = line.contains("##[error]") || line.contains("FAIL") || line.contains("Error:")
                || line.contains("AssertionError")
            if maybe, GitHubCIRun.informative(GitHubCIRun.clean(line)) {
                let context = recent(GitHubCIRun.tailLimit)
                candidate = context + [line]
                candidateStart = total - context.count
                candidateAfter = 2
            }
            if lines.count < GitHubCIRun.windowLines {
                lines.append(line)
            } else {
                lines[start] = line
                start = (start + 1) % lines.count
            }
        }

        private var ordered: [String] { Array(lines[start...] + lines[..<start]) }

        /// The last `count` lines, oldest first, straight from the ring.
        private func recent(_ count: Int) -> [String] {
            let kept = min(count, lines.count)
            return (0 ..< kept).map { lines[(start + lines.count - kept + $0) % lines.count] }
        }

        func tail(limit: Int = GitHubCIRun.tailLimit) -> LogTail {
            let recent = ordered
            let firstNumber = total - recent.count + 1
            if !candidate.isEmpty, candidateStart < firstNumber {
                // The failure rolled out of the ring: its own window explains the log.
                return GitHubCIRun.tail(of: candidate, firstNumber: candidateStart, total: total, limit: limit)
            }
            return GitHubCIRun.tail(of: recent, firstNumber: firstNumber, total: total, limit: limit)
        }
    }

    static func duration(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    // MARK: - Decoding (REST, convertFromSnakeCase)

    static func decodeRun(_ data: Data, decoder: JSONDecoder) throws -> Run {
        let wire = try decoder.decode(RunWire.self, from: data)
        return Run(id: wire.id, name: wire.name, displayTitle: wire.displayTitle, headBranch: wire.headBranch,
                   headSha: wire.headSha, event: wire.event, status: wire.status, conclusion: wire.conclusion,
                   runAttempt: wire.runAttempt ?? 1, htmlUrl: wire.htmlUrl, createdAt: wire.createdAt,
                   updatedAt: wire.updatedAt, runStartedAt: wire.runStartedAt,
                   pullRequests: (wire.pullRequests ?? []).map(\.number))
    }

    static func decodeJobs(_ data: Data, decoder: JSONDecoder) throws -> (jobs: [Job], total: Int) {
        let wire = try decoder.decode(JobsWire.self, from: data)
        let jobs = wire.jobs.map { job in
            Job(id: job.id, name: job.name, status: job.status, conclusion: job.conclusion,
                startedAt: job.startedAt, completedAt: job.completedAt, htmlUrl: job.htmlUrl,
                runnerName: job.runnerName,
                steps: (job.steps ?? []).map {
                    Step(number: $0.number, name: $0.name, status: $0.status, conclusion: $0.conclusion,
                         startedAt: $0.startedAt, completedAt: $0.completedAt)
                })
        }
        return (jobs, wire.totalCount ?? jobs.count)
    }

    // MARK: - The log tail

    /// A job log → the lines that explain it: timestamps and ANSI colour
    /// stripped, group markers dropped, the window ending two lines after the
    /// last failure that says something. Actions closes every failed step
    /// with a generic `##[error]Process completed with exit code N.`; the
    /// anchor is the last failure line above it (`##[error]`, `--- FAIL`,
    /// `FAIL`, `Error:`), the generic line only when nothing else failed. A
    /// log without either keeps its last lines.
    static func tail(of log: String, limit: Int = tailLimit) -> LogTail {
        var lines = log.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return tail(of: lines, firstNumber: 1, total: lines.count, limit: limit)
    }

    /// The same over a window of a longer log: `firstNumber` is the window's
    /// first line in the whole log, `total` the log's line count.
    static func tail(of lines: [String], firstNumber: Int, total: Int, limit: Int = tailLimit) -> LogTail {
        let cleaned = lines.map(clean)
        let anchor = cleaned.lastIndex(where: informative) ?? cleaned.lastIndex { $0.contains("##[error]") }
        let end = anchor.map { min(cleaned.count, $0 + 3) } ?? cleaned.count
        var window: [LogTail.Line] = []
        var index = end - 1
        // Walk back from the end, skipping group markers, until the window is full.
        while index >= 0, window.count < limit {
            let text = cleaned[index]
            if !text.hasPrefix("##[endgroup]") {
                let shown = text.replacingOccurrences(of: "##[error]", with: "")
                    .replacingOccurrences(of: "##[group]", with: "")
                window.append(.init(number: firstNumber + index, text: shown, error: failure(text)))
            }
            index -= 1
        }
        return LogTail(lines: window.reversed(), totalLines: total, anchored: anchor != nil)
    }

    /// A line that reports a failure: Actions' marker or the usual runners'.
    static func failure(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.contains("##[error]") || text.hasPrefix("--- FAIL") || text.hasPrefix("FAIL")
            || text.hasPrefix("Error:") || text.contains("AssertionError")
    }

    /// A failure that says something — not Actions' generic exit line.
    static func informative(_ line: String) -> Bool {
        failure(line) && !line.contains("##[error]Process completed with exit code")
    }

    static func clean(_ line: String) -> String {
        var text = line
        // "2026-10-08T15:12:01.1234567Z " — every Actions log line leads with one.
        if let stamp = text.range(of: #"^\d{4}-\d{2}-\d{2}T[0-9:.]+Z ?"#, options: .regularExpression) {
            text.removeSubrange(stamp)
        }
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }

    // MARK: - Wire

    private struct RunWire: Decodable {
        let id: Int
        let name: String?
        let displayTitle: String?
        let headBranch: String?
        let headSha: String
        let event: String
        let status: String
        let conclusion: String?
        let runAttempt: Int?
        let htmlUrl: String
        let createdAt: Date
        let updatedAt: Date
        let runStartedAt: Date?
        let pullRequests: [PRWire]?

        struct PRWire: Decodable { let number: Int }
    }

    private struct JobsWire: Decodable {
        let totalCount: Int?
        let jobs: [JobWire]
    }

    private struct JobWire: Decodable {
        let id: Int
        let name: String
        let status: String
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
        let htmlUrl: String?
        let runnerName: String?
        let steps: [StepWire]?
    }

    private struct StepWire: Decodable {
        let number: Int
        let name: String
        let status: String
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
    }
}
