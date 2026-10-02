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
}
