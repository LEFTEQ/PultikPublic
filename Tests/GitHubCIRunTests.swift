import XCTest
@testable import Pultik

/// WP6: a failed run's detail — the run and jobs decode, the failing step,
/// the log tail around the error, and ⌘R's revalidation.
final class GitHubCIRunTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func makeRun(status: String = "completed", conclusion: String? = "failure", attempt: Int = 1) throws
        -> GitHubCIRun.Run {
        let body = """
            {"id": 8812, "name": "CI", "display_title": "Provider pool cooldown", "head_branch": "feat/pool",
             "head_sha": "abc1234def", "event": "pull_request", "status": "\(status)",
             "conclusion": \(conclusion.map { "\"\($0)\"" } ?? "null"), "run_attempt": \(attempt),
             "html_url": "https://github.com/o/eve/actions/runs/8812", "created_at": "2026-10-10T15:00:00Z",
             "updated_at": "2026-10-10T15:03:12Z", "run_started_at": "2026-10-10T15:00:00Z",
             "pull_requests": [{"number": 412}]}
            """
        return try GitHubCIRun.decodeRun(Data(body.utf8), decoder: decoder)
    }

    func testRunAndJobsDecodeWithTheFailingJobAndStep() throws {
        let shown = try makeRun()
        XCTAssertTrue(shown.failed)
        XCTAssertEqual(shown.pullRequests, [412])
        let jobs = """
            {"total_count": 2, "jobs": [
              {"id": 1, "name": "lint", "status": "completed", "conclusion": "success",
               "started_at": "2026-10-10T15:00:00Z", "completed_at": "2026-10-10T15:00:41Z", "html_url": "https://x/1",
               "runner_name": "eve-ci-1", "steps": [{"number": 1, "name": "lint", "status": "completed",
               "conclusion": "success", "started_at": null, "completed_at": null}]},
              {"id": 2, "name": "test", "status": "completed", "conclusion": "failure",
               "started_at": "2026-10-10T15:00:00Z", "completed_at": "2026-10-10T15:03:12Z", "html_url": "https://x/2",
               "runner_name": null, "steps": [
                 {"number": 1, "name": "checkout", "status": "completed", "conclusion": "success",
                  "started_at": "2026-10-10T15:00:00Z", "completed_at": "2026-10-10T15:00:02Z"},
                 {"number": 2, "name": "test", "status": "completed", "conclusion": "failure",
                  "started_at": "2026-10-10T15:00:02Z", "completed_at": "2026-10-10T15:01:11Z"},
                 {"number": 3, "name": "post", "status": "completed", "conclusion": "skipped",
                  "started_at": null, "completed_at": null}]}]}
            """
        let page = try GitHubCIRun.decodeJobs(Data(jobs.utf8), decoder: decoder)
        XCTAssertEqual(page.total, 2)
        let cancelledSibling = GitHubCIRun.Job(id: 3, name: "matrix-b", status: "completed", conclusion: "cancelled",
                                               startedAt: nil, completedAt: nil, htmlUrl: nil, runnerName: nil, steps: [])
        let detail = GitHubCIRun.Detail(run: shown, jobs: [cancelledSibling] + page.jobs)
        XCTAssertEqual(detail.failingJob?.name, "test", "a fail-fast-cancelled sibling never leads")
        XCTAssertEqual(detail.failingJob?.failingStep?.name, "test")
        XCTAssertEqual(detail.failingJob?.failingStep?.duration, 69)
        XCTAssertEqual(detail.failingJob?.duration, 192)
    }

    func testTheTailEndsJustAfterTheLastErrorWithoutTimestampsColourOrGroupMarkers() {
        var lines = (1 ... 60).map { "2026-10-10T15:01:\(String(format: "%02d", $0 % 60)).1234567Z line \($0)" }
        lines[49] = "2026-10-10T15:01:50.1Z ##[error]\u{1B}[31mAssertionError: expected 'cooling' to be 'ready'\u{1B}[0m"
        lines[45] = "2026-10-10T15:01:46.1Z ##[group]Run npm test"
        lines[46] = "2026-10-10T15:01:47.1Z ##[endgroup]"
        let tail = GitHubCIRun.tail(of: lines.joined(separator: "\n") + "\n", limit: 10)
        XCTAssertTrue(tail.anchored)
        XCTAssertEqual(tail.totalLines, 60)
        XCTAssertEqual(tail.lines.last?.number, 52, "two lines past the error")
        XCTAssertEqual(tail.lines.count, 10)
        let error = tail.lines.first { $0.error }
        XCTAssertEqual(error?.number, 50)
        XCTAssertEqual(error?.text, "AssertionError: expected 'cooling' to be 'ready'")
        XCTAssertFalse(tail.lines.contains { $0.text.contains("##[") }, "markers are dropped or stripped")
        XCTAssertFalse(tail.lines.contains { $0.number == 47 }, "an endgroup line is not a line worth showing")
        XCTAssertEqual(tail.lines.first { $0.number == 46 }?.text, "Run npm test")

        // The generic exit line closes every failed step; the tail anchors above it.
        let goTest = ["=== RUN TestPool", "--- FAIL: TestPool (0.01s)", "FAIL", "FAIL\tgithub.com/o/eve/pool 1.2s",
                      "ok  \tgithub.com/o/eve/web 0.4s", "##[error]Process completed with exit code 1."]
        let go = GitHubCIRun.tail(of: goTest.joined(separator: "\n"), limit: 40)
        XCTAssertEqual(go.lines.last?.number, 6, "two past the last real failure, line 4")
        XCTAssertEqual(go.lines.filter(\.error).map(\.number), [2, 3, 4, 6])

        // A streamed log keeps its recent window and its true line numbers.
        var window = GitHubCIRun.LogWindow()
        for number in 1 ... GitHubCIRun.windowLines + 500 { window.append(number == 4450 ? "FAIL pool" : "line \(number)") }
        let streamed = window.tail(limit: 5)
        XCTAssertEqual(streamed.totalLines, GitHubCIRun.windowLines + 500)
        XCTAssertEqual(streamed.lines.map(\.number), [4448, 4449, 4450, 4451, 4452])
        XCTAssertTrue(streamed.lines[2].error)

        // A failure followed by more cleanup than the ring holds is still the anchor.
        var buried = GitHubCIRun.LogWindow()
        for number in 1 ... 10 + GitHubCIRun.windowLines * 2 {
            buried.append(number == 10 ? "--- FAIL: TestPool" : number == 11 ? "FAIL\tgithub.com/o/eve/pool" : "cleanup \(number)")
        }
        let explained = buried.tail(limit: 5)
        XCTAssertEqual(explained.lines.map(\.number), [9, 10, 11, 12, 13])
        XCTAssertEqual(explained.lines.filter(\.error).map(\.number), [10, 11])

        let quiet = GitHubCIRun.tail(of: "a\nb\nc", limit: 2)
        XCTAssertFalse(quiet.anchored)
        XCTAssertEqual(quiet.lines.map(\.text), ["b", "c"])
    }

    func testCommandRReRunsOnlyTheFailedAttemptOnScreen() throws {
        let shown = try makeRun()
        XCTAssertEqual(GitHubCIRun.Revalidation.judge(shown: shown, fresh: try makeRun()), .rerun)
        XCTAssertEqual(GitHubCIRun.Revalidation.judge(shown: shown, fresh: try makeRun(status: "in_progress", conclusion: nil)),
                       .running)
        XCTAssertEqual(GitHubCIRun.Revalidation.judge(shown: shown, fresh: try makeRun(conclusion: "failure", attempt: 2)),
                       .newerAttempt(2))
        XCTAssertEqual(GitHubCIRun.Revalidation.judge(shown: shown, fresh: try makeRun(conclusion: "success")),
                       .notFailed("success"))
    }
}
