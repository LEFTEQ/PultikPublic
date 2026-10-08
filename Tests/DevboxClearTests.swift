import XCTest
@testable import Pultik

final class DevboxClearTests: XCTestCase {
    func testFailureKeepsAllDiagnosticsInstructionsAndCommandOutput() {
        let output = """
        {"ok":false,"diagnostics":[
          {"code":"BOX_UNREACHABLE","severity":"warning","detail":"Another box did not answer"},
          {"code":"WS_CLEAR_FAILED","severity":"error","detail":"Workspace is held","fix":"devbox unhold demo --box b"}
        ],"next":["devbox unhold demo --box b"]}
        """
        let report = DevboxClearReport.command(["clear", "demo", "--box", "b"], ok: false, stdout: output, stderr: "transport details\nsecond line")
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.summary, "Workspace is held")
        XCTAssertEqual(report.diagnostics.count, 2)
        XCTAssertEqual(report.next, ["devbox unhold demo --box b"])
        XCTAssertTrue(report.log.contains(output))
        XCTAssertTrue(report.log.contains("transport details\nsecond line"))
        let malformed = DevboxClearReport.command(["clear", "demo"], ok: false, stdout: "unexpected output", stderr: "connection refused")
        XCTAssertFalse(malformed.ok)
        XCTAssertTrue(malformed.log.contains("unexpected output"))
        XCTAssertTrue(malformed.log.contains("connection refused"))
    }

    func testSummaryJoinsStatusWithNumstatAndJudgesTheChosenAction() {
        var preview = DevboxClearPreview(path: "/w", status: " M src/a.ts\nR  old.ts -> src/b.ts\n?? notes.md\nUU merge.ts\n",
                                         diff: "", commits: "abc1234 feat: first\ndef5678 fix: second\n", canRemove: true, complete: true,
                                         explanation: "", fingerprint: "", log: "")
        preview.numstat = "12\t3\tsrc/a.ts\n-\t-\tsrc/b.ts\n"
        preview.upstream = "origin/feat"
        preview.changesRead = true
        let summary = DevboxClearSummary(preview)
        XCTAssertEqual(summary.files.map(\.kind), ["M", "R", "?", "U"])
        XCTAssertEqual(summary.files[1].path, "src/b.ts")
        XCTAssertNil(summary.files[1].added)
        XCTAssertEqual([summary.added, summary.removed], [12, 3])
        XCTAssertEqual(summary.commits.last, .init(sha: "def5678", subject: "fix: second"))
        XCTAssertEqual(DevboxClearSummary.verdict([summary], action: .keep), .keepsWork)
        XCTAssertEqual(DevboxClearSummary.verdict([summary], action: .discard), .discards(files: 4))
        var clean = DevboxClearPreview(path: "/w", status: "", diff: "", commits: "", canRemove: true, complete: false,
                                       explanation: "", fingerprint: "", log: "")
        clean.changesRead = true
        XCTAssertEqual(DevboxClearSummary.verdict([DevboxClearSummary(clean)], action: .discard), .clean)
        XCTAssertEqual(DevboxClearSummary.verdict([DevboxClearSummary(clean), summary], action: .keep), .keepsWork)
        clean.changesRead = false
        XCTAssertEqual(DevboxClearSummary.verdict([DevboxClearSummary(clean)], action: .keep), .unread)
    }
}
