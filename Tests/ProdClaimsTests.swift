import XCTest
@testable import Pultik

/// The one predicate deciding whether the prod board owns an alert or the
/// Mac's Sentry fallback is hidden (contracts §4–§5).
final class ProdClaimsTests: XCTestCase {
    private func digest(verdict: String = "ok", alertmanagerOK: Bool = true, sentryOK: Bool = true) -> HlidacDigest {
        let json = """
        {"generatedAt": "2026-10-02T18:41:00Z",
         "sources": {"prometheus": {"ok": true, "since": null, "error": null},
                     "alertmanager": {"ok": \(alertmanagerOK), "since": null, "error": null},
                     "sentry": {"ok": \(sentryOK), "since": null, "error": null}},
         "deployments": [{"key": "exampleapp-prod", "project": "exampleapp", "title": "ExampleApp prod", "tier": "critical",
           "verdict": "\(verdict)", "blindSince": null, "emergency": false, "checks": [],
           "logs": {"hours": null, "today": null, "yesterday": null}, "edge": null,
           "sentry": [], "alerts": [], "pool": null, "links": []}]}
        """
        return HlidacDigest.decode(Data(json.utf8))!
    }

    private func alert(deployment: String?) -> FiringAlert {
        var labels = ["alertname": "ExampleappProdApiDown", "severity": "critical"]
        labels["deployment"] = deployment
        return FiringAlert(name: "ExampleappProdApiDown", state: "firing", severity: "critical", summary: nil,
                           description: nil, labels: labels, activeAt: nil, source: .prometheus)
    }

    func testClaimsOnlyWhatALiveDigestCanShow() {
        let labelled = alert(deployment: "exampleapp-prod")
        XCTAssertTrue(ProdClaims.isClaimed(alert: labelled, digest: digest(), unreachableSince: nil, pointers: []))
        // No digest, stale digest, unknown or unwatched deployment, failed
        // Alertmanager source, unlabelled alert: the estate path keeps it.
        XCTAssertFalse(ProdClaims.isClaimed(alert: labelled, digest: nil, unreachableSince: nil, pointers: []))
        XCTAssertFalse(ProdClaims.isClaimed(alert: labelled, digest: digest(), unreachableSince: Date(),
                                            pointers: []))
        XCTAssertFalse(ProdClaims.isClaimed(alert: alert(deployment: "booking-sk"), digest: digest(),
                                            unreachableSince: nil, pointers: []))
        XCTAssertFalse(ProdClaims.isClaimed(alert: labelled, digest: digest(verdict: "blind"), unreachableSince: nil,
                                            pointers: []))
        XCTAssertFalse(ProdClaims.isClaimed(alert: labelled, digest: digest(verdict: "unmonitored"),
                                            unreachableSince: nil, pointers: []))
        XCTAssertFalse(ProdClaims.isClaimed(alert: labelled, digest: digest(alertmanagerOK: false),
                                            unreachableSince: nil, pointers: []))
        XCTAssertFalse(ProdClaims.isClaimed(alert: alert(deployment: nil), digest: digest(), unreachableSince: nil,
                                            pointers: []))
    }

    /// Pointers narrow the board (ProdGlance's selection), so they narrow
    /// the claim: a deployment the board leaves out keeps its alerts on the
    /// estate path, where FIRING shows them and FiringWatch announces them.
    func testClaimsOnlyDeploymentsTheBoardShows() {
        let labelled = alert(deployment: "exampleapp-prod")
        XCTAssertTrue(ProdClaims.isClaimed(alert: labelled, digest: digest(), unreachableSince: nil,
                                           pointers: [ProdPointer(key: "exampleapp-prod")]))
        XCTAssertFalse(ProdClaims.isClaimed(alert: labelled, digest: digest(), unreachableSince: nil,
                                            pointers: [ProdPointer(key: "booking-sk")]))
    }

    func testSentryLiveHidesTheMacFallbackOnlyWhileHlidacServesSentry() {
        XCTAssertTrue(ProdClaims.sentryLive(digest: digest(), unreachableSince: nil))
        XCTAssertFalse(ProdClaims.sentryLive(digest: nil, unreachableSince: nil))
        XCTAssertFalse(ProdClaims.sentryLive(digest: digest(), unreachableSince: Date()))
        XCTAssertFalse(ProdClaims.sentryLive(digest: digest(sentryOK: false), unreachableSince: nil))
    }
}
