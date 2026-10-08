import XCTest
@testable import Pultik

/// The Mac health contract with toolkit: `Tests/Fixtures/macwatch-health.json`
/// is a copy of toolkit's `docs/macwatch-health.example.json` (contract v1,
/// `internal/macwatch/health.go`) — re-copy it when the contract moves.
final class MacHealthTests: XCTestCase {
    private static let generatedAt = ISO8601DateFormatter().date(from: "2026-10-04T13:01:41Z")!

    private func fixture(_ edit: (String) -> String = { $0 }) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/macwatch-health.json")
        return Data(edit(try String(contentsOf: url, encoding: .utf8)).utf8)
    }

    private func golden() throws -> MacHealth {
        try MacHealth.decode(try fixture()).get()
    }

    func testFixtureDecodesEveryField() throws {
        let health = try golden()
        XCTAssertEqual(health.generatedAt, Self.generatedAt)
        XCTAssertEqual(health.windowSeconds, 60)
        XCTAssertEqual(health.machine.cores, 14)
        XCTAssertEqual(health.machine.memUsedGb, 93)
        XCTAssertEqual(health.machine.swapTotalGb, 6)
        XCTAssertEqual(health.headline.severity, .red)
        XCTAssertEqual(health.headline.text, "3 likely orphans · 12% CPU · 6.0 GB · +2 worth a look")
        XCTAssertEqual(health.families.count, 10)
        XCTAssertEqual(health.families.first?.health, .amber)
        XCTAssertEqual(health.network.top.map(\.tunnel), [false, true, false])
        XCTAssertEqual(health.diagnostics, [])

        let emulator = try XCTUnwrap(health.findings.first)
        XCTAssertEqual(emulator.processes.first?.pid, 22504)
        XCTAssertEqual(emulator.stop.argv?.first, "toolkit")
        XCTAssertNil(emulator.project)
        let codex = try XCTUnwrap(health.findings.last)
        XCTAssertEqual(codex.project, "example-org/build-server-infra")
        XCTAssertFalse(codex.stop.supported)
        XCTAssertEqual(codex.stop.reason, "an agent session — close its terminal tab")
        XCTAssertEqual(health.findingsWorstFirst.map(\.severity), [.red, .red, .red, .amber, .amber])
        XCTAssertEqual(MacHealthFormat.cost(emulator), "12% CPU · 5.9 GB")
        XCTAssertEqual(MacHealthFormat.rate(2_600_000), "2.6 MB/s")
        XCTAssertEqual(MacHealthFormat.rate(300_000), "300 KB/s")
    }

    /// Another version hides the feature — the gate reads the version alone,
    /// so a v2 file never half-decodes into v1 types.
    func testAnotherVersionIsRefusedNotHalfDecoded() throws {
        let v2 = try fixture { $0.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2") }
        XCTAssertEqual(MacHealth.decode(v2).failure, .version(2))
        let v2Reshaped = Data(#"{"version": 2, "machine": "elsewhere"}"#.utf8)
        XCTAssertEqual(MacHealth.decode(v2Reshaped).failure, .version(2))
        guard case .unreadable = MacHealth.decode(Data("{}".utf8)).failure else {
            return XCTFail("a file without a version is unreadable")
        }
    }

    /// Missing → hidden; three minutes old → stale (no chip); fresh → chip.
    @MainActor
    func testMissingOrStaleReportHidesTheChip() throws {
        let missing = MacHealthStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "pultik-no-such-health-\(UUID().uuidString).json"))
        missing.reread()
        XCTAssertEqual(missing.status, .hidden)
        XCTAssertNil(missing.status.chip)

        let health = try golden()
        let stale = MacHealthStatus.make(health, now: Self.generatedAt.addingTimeInterval(181))
        XCTAssertEqual(stale, .stale(health))
        XCTAssertNil(stale.chip)
        XCTAssertNotNil(MacHealthStatus.make(health, now: Self.generatedAt.addingTimeInterval(170)).chip)
    }

    /// The chip shows toolkit's headline verbatim, only when it says something.
    func testChipNeedsHeadlineText() throws {
        let chip = try XCTUnwrap(MacHealthStatus.make(try golden(), now: Self.generatedAt).chip)
        XCTAssertEqual(chip.text, "3 likely orphans · 12% CPU · 6.0 GB · +2 worth a look")
        XCTAssertEqual(chip.severity, .red)
        XCTAssertTrue(chip.help.hasPrefix("● Android emulator exampleapp_pixel8\n● log stream left running"))

        let quiet = try MacHealth.decode(try fixture {
            $0.replacingOccurrences(of: #""text": "3 likely orphans · 12% CPU · 6.0 GB · +2 worth a look""#, with: #""text": """#)
        }).get()
        XCTAssertNil(MacHealthStatus.make(quiet, now: Self.generatedAt).chip)
    }

    func testSquarifyIsProportionalInsideAndNonOverlapping() throws {
        let values = try golden().families.map(\.memMb) + [0]
        let bounds = CGRect(x: 0, y: 0, width: 272, height: 272)
        let rects = Treemap.squarify(values, in: bounds)
        let total = values.reduce(0, +)

        XCTAssertEqual(rects.count, values.count)
        XCTAssertEqual(rects.last, .zero)
        for (value, rect) in zip(values, rects) where value > 0 {
            XCTAssertEqual(Double(rect.width * rect.height), value / total * 272 * 272, accuracy: 0.01)
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(rect), "\(rect) escapes")
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let overlap = rects[i].intersection(rects[j])
                XCTAssertLessThan(overlap.isNull ? 0 : overlap.width * overlap.height, 0.001)
            }
        }
    }

    /// A GUI app has no shell PATH: `toolkit` resolves to the first installed
    /// copy, anything else bare is refused rather than searched for.
    func testStopResolvesToolkitToAnAbsolutePath() {
        let argv = ["toolkit", "macwatch", "stop", "--json", "--pid", "22504"]
        let local = NSHomeDirectory() + "/.local/bin/toolkit"
        XCTAssertEqual(MacHealthStop.resolve(argv) { $0 == local }, [local] + argv.dropFirst())
        XCTAssertEqual(MacHealthStop.resolve(argv) { _ in true }?.first, "/opt/homebrew/bin/toolkit")
        XCTAssertNil(MacHealthStop.resolve(argv) { _ in false })
        XCTAssertNil(MacHealthStop.resolve(["kill", "22504"]) { _ in true })

    }

    /// `macwatch stop --json` answers per process; any refusal is the
    /// outcome, and it names what did stop alongside.
    func testStopOutcomeReadsTheReply() {
        let names = [45691: "tail", 45695: "ugrep"]
        let both = Data(#"{"stopped":[{"pid":45691,"signal":"TERM"},{"pid":45695,"signal":"KILL"}],"refused":null}"#.utf8)
        XCTAssertEqual(MacHealthStop.outcome(status: 0, stdout: both, stderr: "", names: names),
                       .stopped("stopped tail (45691), ugrep (45695) after SIGKILL"))
        let mixed = Data(#"{"stopped":[{"pid":45691,"signal":"TERM"}],"refused":[{"pid":45695,"reason":"start time changed"}]}"#.utf8)
        XCTAssertEqual(MacHealthStop.outcome(status: 1, stdout: mixed, stderr: "", names: names),
                       .refused("ugrep (45695) — start time changed; stopped tail (45691)"))
        XCTAssertEqual(MacHealthStop.outcome(status: 2, stdout: Data(), stderr: "unknown flag --pid\n"),
                       .refused("unknown flag --pid"))
    }
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
