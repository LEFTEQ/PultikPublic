import XCTest
@testable import Pultik

/// The first Now adapters (docs/specs/2026-10-09-now-queue-contracts.md, "Sources"):
/// only the ones whose mapping carries logic worth pinning.
final class NowAdaptersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_465_120) // 2026-10-08T13:12:00Z
    private let origin = "hlidac.test"

    private func iso(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }

    private func digest(sentryOK: Bool) throws -> HlidacDigest {
        let sentry = sentryOK ? #"{"ok":true}"# : #"{"ok":false,"since":"2026-10-08T12:40:00Z","error":"timeout"}"#
        let issue = #"{"id":"%@","shortId":"%@","title":"t","project":"p","environment":"production","count":1,"#
            + #""users":1,"firstSeen":"2026-10-01T08:00:00Z","lastSeen":"2026-10-08T13:10:00Z","permalink":null,"isNew":false}"#
        func deployment(_ key: String, _ verdict: String, blindSince: String? = nil, issues: [String] = []) -> String {
            let blind = blindSince.map { #","blindSince":"\#($0)""# } ?? ""
            let sentry = issues.map { String(format: issue, $0, $0) }.joined(separator: ",")
            return #"{"key":"\#(key)","project":"p","title":"\#(key)","tier":"critical","verdict":"\#(verdict)""#
                + #"\#(blind),"emergency":false,"checks":[],"logs":{},"sentry":[\#(sentry)],"alerts":[],"links":[]}"#
        }
        let json = #"{"generatedAt":"2026-10-08T13:12:00Z","sources":{"prometheus":{"ok":true},"#
            + #""alertmanager":{"ok":true},"sentry":\#(sentry)},"deployments":["#
            + [deployment("exampleapp-prod", "down", issues: ["EXAMPLEAPP-API-9Q"]),
               deployment("vitrinka", "blind", blindSince: "2026-10-08T12:50:00Z"),
               deployment("booking-sk", "ok", issues: ["BOOKING-1"])].joined(separator: ",")
            + "]}"
        return try XCTUnwrap(HlidacDigest.decode(Data(json.utf8)))
    }

    /// A failing Hlídač source and a blind deployment are on fire from their
    /// own since; unreachable Hlídač is one transport need and judges nothing
    /// from the cached digest.
    func testHlidacBlindnessStartsAtTheFailuresOwnSince() throws {
        let digest = try digest(sentryOK: false)
        let read = NowAdapters.hlidacBlindness(digest: digest, unreachableSince: nil, origin: origin, now: now)
        XCTAssertEqual(read.coverage, .complete)
        XCTAssertEqual(read.needs.map(\.needID), ["hlidac:hlidac.test:blind:sentry",
                                                  "hlidac:hlidac.test:blind:deployment:vitrinka"])
        XCTAssertEqual(read.needs.map(\.onset), [.exact(iso("2026-10-08T12:40:00Z")), .exact(iso("2026-10-08T12:50:00Z"))])
        XCTAssertEqual(read.needs.map(\.lane), [.onFire, .onFire])
        XCTAssertEqual(read.needs[1].incidentKey, "hlidac:hlidac.test:deployment:vitrinka")
        XCTAssertEqual(NowAdapters.hlidacSentry(digest: digest, unreachableSince: nil, origin: origin, now: now).coverage,
                       .failed)

        let away = iso("2026-10-08T13:05:00Z")
        let blind = NowAdapters.hlidacBlindness(digest: digest, unreachableSince: away, origin: origin, now: now)
        XCTAssertEqual(blind.coverage, .partial)
        XCTAssertEqual(blind.needs.map(\.needID), ["hlidac:hlidac.test:blind:transport"])
        XCTAssertEqual(blind.needs.first?.onset, .exact(away))
    }

    /// An unhealthy deployment's Sentry issue and the firing alert the prod
    /// board claims join the deployment's one row; the issue's lifetime
    /// first-seen never backdates it. An ok deployment's issue stays in
    /// Prod, an unclaimed warning drifts on its own row, pending is no need.
    func testSentryIssueAndClaimedAlertJoinTheDeploymentIncident() throws {
        let digest = try digest(sentryOK: true)
        let sentry = NowAdapters.hlidacSentry(digest: digest, unreachableSince: nil, origin: origin, now: now)
        XCTAssertEqual(sentry.coverage, .complete)
        XCTAssertEqual(sentry.needs.map(\.displayID), ["EXAMPLEAPP-API-9Q"])
        XCTAssertEqual(sentry.needs.first?.onset, .firstSeen(iso("2026-10-01T08:00:00Z")))

        func alert(_ name: String, _ state: String, _ severity: String, _ labels: [String: String]) -> FiringAlert {
            FiringAlert(name: name, state: state, severity: severity, summary: name, description: nil,
                        labels: labels.merging(["alertname": name, "severity": severity]) { $1 },
                        activeAt: iso("2026-10-08T12:57:00Z"), source: .prometheus)
        }
        let estate = NowAdapters.estateAlerts(
            [alert("ExampleappProdJobsStuck", "firing", "critical", ["deployment": "exampleapp-prod"]),
             alert("DiskTrendingLow", "firing", "warning", ["host": "web-server"]),
             alert("SwapHigh", "pending", "warning", ["host": "devbox-b"])],
            digest: digest, unreachableSince: nil, pointers: [], hlidacOrigin: origin, origin: "build-server", now: now)
        XCTAssertEqual(estate.needs.map(\.needID), ["estate:prometheus:ExampleappProdJobsStuck:deployment=exampleapp-prod",
                                                    "estate:prometheus:DiskTrendingLow:host=web-server"])
        XCTAssertEqual(estate.needs.map(\.lane), [.onFire, .drifting])

        let queue = NowQueue.build(needs: sentry.needs + estate.needs, now: now)
        let prod = try XCTUnwrap(queue.incident("hlidac:hlidac.test:deployment:exampleapp-prod"))
        XCTAssertEqual(prod.needs.map(\.kind), [.firingAlert, .sentryIssue])
        XCTAssertEqual(prod.onset, .exact(iso("2026-10-08T12:57:00Z")))
        XCTAssertEqual(queue.lanes.map(\.incidents), [1, 0, 0, 1])
    }

    /// A ruler that did not answer leaves its rules missing, not resolved:
    /// the read is partial, so the ledger keeps the firing need open.
    /// vt-7727 AC 5: Mac joined Estate, so This Mac's findings open there,
    /// on the finding's own row under This Mac.
    func testMacFindingsLandOnEstate() throws {
        let finding = NowInputs.MacFinding(id: "f1", severity: .red, title: "Agent shell left running",
                                           detail: "claude ×3", since: now.addingTimeInterval(-3600), stopSupported: true)
        let read = NowAdapters.macFindings(NowInputs.MacReport(generatedAt: now, findings: [finding]),
                                           machine: "mac", now: now)
        let target = try XCTUnwrap(read.needs.first?.target)
        XCTAssertEqual(target.module, .estate)
        XCTAssertEqual(target.objectID, "finding:f1")
    }

    func testSilentRulerNeverClearsAFiringNeed() throws {
        let firing = FiringAlert(name: "LokiErrors", state: "firing", severity: "critical", summary: nil,
                                 description: nil, labels: ["alertname": "LokiErrors", "app": "exampleapp"],
                                 activeAt: iso("2026-10-08T12:57:00Z"), source: .loki)
        func read(_ alerts: [FiringAlert], complete: Bool) -> NowRead {
            NowAdapters.estateAlerts(alerts, complete: complete, digest: nil, unreachableSince: nil, pointers: [],
                                     hlidacOrigin: origin, origin: "build-server", now: now)
        }
        var ledger = ObservationLedger()
        _ = ledger.record(read([firing], complete: true), now: now)
        let silent = read([], complete: false)
        XCTAssertEqual(silent.coverage, .partial)
        _ = ledger.record(silent, now: now.addingTimeInterval(90))
        XCTAssertEqual(ledger.handled(now: now.addingTimeInterval(90)), [])
    }

}
