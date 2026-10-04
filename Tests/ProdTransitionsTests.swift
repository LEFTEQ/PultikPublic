import UserNotifications
import XCTest
@testable import Pultik

/// Which prod-board changes notify, and how hard (decision log D9 L1, D10;
/// brief AC9; the lead's Time Sensitive policy).
final class ProdTransitionsTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-02T18:41:00Z")!

    private struct Spec {
        var key = "exampleapp-prod"
        var title = "ExampleApp prod"
        var tier = "critical"
        var verdict = "ok"
        var down: [String] = [] // failing check ids (status 0)
        var alerts: [(name: String, emergency: Bool)] = []
    }

    private func digest(_ specs: [Spec]) -> HlidacDigest {
        let deployments = specs.map { spec -> String in
            let checks = ["api", "web"].map { id in
                let up = !spec.down.contains(id)
                return #"{"id": "\#(id)", "title": "\#(id.uppercased())", "status": \#(up ? 1 : 0), "value": "\#(up ? "ok" : "502")", "page": true}"#
            }
            let alerts = spec.alerts.map { alert in
                #"{"name": "\#(alert.name)", "severity": "critical", "summary": "\#(alert.name) fired", "activeAt": null, "emergency": \#(alert.emergency), "url": null}"#
            }
            let emergency = spec.alerts.contains { $0.emergency }
            return """
            {"key": "\(spec.key)", "project": "p", "title": "\(spec.title)", "tier": "\(spec.tier)",
             "verdict": "\(spec.verdict)", "blindSince": null, "emergency": \(emergency),
             "checks": [\(checks.joined(separator: ","))],
             "logs": {"hours": null, "today": null, "yesterday": null}, "edge": null,
             "sentry": [], "alerts": [\(alerts.joined(separator: ","))], "pool": null, "links": []}
            """
        }
        let json = #"{"generatedAt": "2026-10-02T18:41:00Z", "sources": {}, "deployments": [\#(deployments.joined(separator: ","))]}"#
        return HlidacDigest.decode(Data(json.utf8))!
    }

    private func digest(_ spec: Spec) -> HlidacDigest {
        digest([spec])
    }

    private func primed(_ spec: Spec = Spec()) -> ProdTransitions {
        var watch = ProdTransitions()
        _ = watch.update(digest: digest(spec), unreachableSince: nil, now: t0)
        return watch
    }

    func testFirstAnswerIsSilentEvenWhenRed() {
        var watch = ProdTransitions()
        let red = Spec(verdict: "down", down: ["api"])
        XCTAssertEqual(watch.update(digest: digest(red), unreachableSince: nil, now: t0), [])
        XCTAssertEqual(watch.update(digest: digest(red), unreachableSince: nil, now: t0 + 15), [])
    }

    /// AC9 + policy: a critical-tier red is Time Sensitive and bypasses
    /// FocusGate; the built content carries `.timeSensitive`.
    func testCriticalRedIsTimeSensitiveAndBypassesFocus() throws {
        var watch = primed()
        let red = watch.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil,
                               now: t0 + 15)
        let notice = try XCTUnwrap(red.first)
        XCTAssertEqual(red.count, 1)
        XCTAssertEqual(notice.title, "🔴 ExampleApp prod · API down")
        XCTAssertEqual(notice.body, "API 502")
        XCTAssertEqual(notice.interruption, .timeSensitive)
        XCTAssertTrue(notice.bypassesFocus)
        let content = NotificationContent.make(title: notice.title, body: notice.body,
                                               url: "pultik://panel/prod/exampleapp-prod", thread: "prod.exampleapp-prod",
                                               interruption: notice.interruption)
        XCTAssertEqual(content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(content.threadIdentifier, "prod.exampleapp-prod")
        XCTAssertEqual(content.userInfo["url"] as? String, "pultik://panel/prod/exampleapp-prod")
        XCTAssertNotNil(content.sound)
    }

    func testWatchTierRedIsAnOrdinaryBannerThroughFocusButItsEmergencyIsNot() {
        var watch = primed(Spec(key: "vitrinka", title: "vitrinka", tier: "watch"))
        let red = watch.update(digest: digest(Spec(key: "vitrinka", title: "vitrinka", tier: "watch",
                                                   verdict: "down", down: ["web"])),
                               unreachableSince: nil, now: t0 + 15)
        XCTAssertEqual(red.map(\.interruption), [.active])
        XCTAssertEqual(red.map(\.bypassesFocus), [false])
        let emergency = watch.update(digest: digest(Spec(key: "vitrinka", title: "vitrinka", tier: "watch",
                                                         verdict: "down", down: ["web"],
                                                         alerts: [("VitrinkaDown", true)])),
                                     unreachableSince: nil, now: t0 + 30)
        XCTAssertEqual(emergency.map(\.interruption), [.timeSensitive])
        XCTAssertEqual(emergency.map(\.bypassesFocus), [true])
    }

    /// Within one red episode: a new failing check and a second emergency
    /// each speak; an emergency that drops and returns speaks again.
    func testNewReasonsAndARepeatedEmergencySpeakWithinOneRedEpisode() {
        var watch = primed()
        _ = watch.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil, now: t0 + 15)
        let web = watch.update(digest: digest(Spec(verdict: "down", down: ["api", "web"])), unreachableSince: nil,
                               now: t0 + 30)
        XCTAssertEqual(web.map(\.title), ["🔴 ExampleApp prod · WEB down"])
        XCTAssertEqual(web.first?.body, "API 502 · WEB 502")

        let first = watch.update(digest: digest(Spec(verdict: "down", down: ["api", "web"],
                                                     alerts: [("ExampleappProdApiDown", true)])),
                                 unreachableSince: nil, now: t0 + 45)
        XCTAssertEqual(first.map(\.title), ["🚨 ExampleApp prod · ExampleappProdApiDown fired"])
        let second = watch.update(digest: digest(Spec(verdict: "down", down: ["api", "web"],
                                                      alerts: [("ExampleappProdApiDown", true), ("EveExampleappChatAbsent", true)])),
                                  unreachableSince: nil, now: t0 + 60)
        XCTAssertEqual(second.map(\.title), ["🚨 ExampleApp prod · EveExampleappChatAbsent fired"])
        // Nothing new: silent.
        XCTAssertEqual(watch.update(digest: digest(Spec(verdict: "down", down: ["api", "web"],
                                                        alerts: [("ExampleappProdApiDown", true), ("EveExampleappChatAbsent", true)])),
                                    unreachableSince: nil, now: t0 + 75), [])
    }

    func testEmergencyThatDropsAndReturnsSpeaksAgainWhileStillRed() {
        var watch = primed()
        let siren = Spec(verdict: "down", down: ["api"], alerts: [("ExampleappProdApiDown", true)])
        XCTAssertEqual(watch.update(digest: digest(siren), unreachableSince: nil, now: t0 + 15).count, 1)
        // The emergency clears, the deployment stays red.
        XCTAssertEqual(watch.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil,
                                    now: t0 + 30), [])
        // It fires again: still red, but an escalation is news.
        let again = watch.update(digest: digest(siren), unreachableSince: nil, now: t0 + 45)
        XCTAssertEqual(again.map(\.interruption), [.timeSensitive])
    }

    func testRecoveryNotifiesOnlyAfterAnAnnouncedRed() {
        var silent = ProdTransitions()
        _ = silent.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil, now: t0)
        XCTAssertEqual(silent.update(digest: digest(Spec()), unreachableSince: nil, now: t0 + 15), [])

        var watch = primed()
        _ = watch.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil, now: t0 + 15)
        let recovered = watch.update(digest: digest(Spec()), unreachableSince: nil, now: t0 + 30)
        XCTAssertEqual(recovered.map(\.title), ["✅ ExampleApp prod recovered"])
        XCTAssertEqual(recovered.first?.interruption, .active)
        XCTAssertEqual(recovered.first?.bypassesFocus, false)
    }

    func testFlapWithinThirtyMinutesStaysQuietUntilTheWindowPasses() {
        var watch = primed()
        let red = Spec(verdict: "down", down: ["api"])
        _ = watch.update(digest: digest(red), unreachableSince: nil, now: t0 + 15)
        _ = watch.update(digest: digest(Spec()), unreachableSince: nil, now: t0 + 60)
        XCTAssertEqual(watch.update(digest: digest(red), unreachableSince: nil, now: t0 + 660), [])
        XCTAssertEqual(watch.update(digest: digest(red), unreachableSince: nil,
                                    now: t0 + 60 + ProdTransitions.flapWindow + 1).count, 1)
        XCTAssertEqual(watch.update(digest: digest(red), unreachableSince: nil,
                                    now: t0 + 60 + ProdTransitions.flapWindow + 16), [])
    }

    /// Blind is unknown — no red, no recovery — but an emergency on a blind
    /// deployment always speaks. Unreachable says nothing at all.
    func testBlindIsSilentButItsEmergencySpeaksAndUnreachableIsSilent() {
        var watch = primed()
        _ = watch.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil, now: t0 + 15)
        XCTAssertEqual(watch.update(digest: digest(Spec(verdict: "blind")), unreachableSince: nil, now: t0 + 30), [])
        XCTAssertEqual(watch.update(digest: nil, unreachableSince: t0 + 40, now: t0 + 3600), [])

        var blind = primed()
        let siren = blind.update(digest: digest(Spec(verdict: "blind", alerts: [("ExampleappProdApiDown", true)])),
                                 unreachableSince: nil, now: t0 + 15)
        XCTAssertEqual(siren.map(\.title), ["🚨 ExampleApp prod · ExampleappProdApiDown fired"])
        XCTAssertEqual(siren.map(\.interruption), [.timeSensitive])
    }

    /// Blind on its first sighting (a cold start during an upstream outage)
    /// is observed-but-unknown, not unseen: the first healthy answer
    /// establishes health silently, but a down after it is news.
    func testBlindFirstSightingThenDownNotifiesButThenOkIsSilent() {
        var watch = ProdTransitions()
        XCTAssertEqual(watch.update(digest: digest(Spec(verdict: "blind")), unreachableSince: nil, now: t0), [])
        let red = watch.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil,
                               now: t0 + 15)
        XCTAssertEqual(red.map(\.title), ["🔴 ExampleApp prod · API down"])

        var healthy = ProdTransitions()
        _ = healthy.update(digest: digest(Spec(verdict: "blind")), unreachableSince: nil, now: t0)
        XCTAssertEqual(healthy.update(digest: digest(Spec()), unreachableSince: nil, now: t0 + 15), [])
        XCTAssertEqual(healthy.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil,
                                      now: t0 + 30).count, 1)
    }

    /// A red baselined at launch (or on a later first sighting) keeps its
    /// reasons for the whole episode: a reason that dips and returns while
    /// the deployment stays red is not new.
    func testBaselineReasonsHoldForTheWholeInitialRedEpisode() {
        var watch = ProdTransitions()
        let both = Spec(verdict: "down", down: ["api", "web"])
        _ = watch.update(digest: digest(both), unreachableSince: nil, now: t0)
        XCTAssertEqual(watch.update(digest: digest(Spec(verdict: "down", down: ["web"])), unreachableSince: nil,
                                    now: t0 + 15), [])
        XCTAssertEqual(watch.update(digest: digest(both), unreachableSince: nil, now: t0 + 30), [])

        var later = primed()
        let sk = Spec(key: "booking-sk", title: "Booking SK", verdict: "down", down: ["api", "web"])
        _ = later.update(digest: digest([Spec(), sk]), unreachableSince: nil, now: t0 + 15)
        var dipped = sk
        dipped.down = ["web"]
        XCTAssertEqual(later.update(digest: digest([Spec(), dipped]), unreachableSince: nil, now: t0 + 30), [])
        XCTAssertEqual(later.update(digest: digest([Spec(), sk]), unreachableSince: nil, now: t0 + 45), [])
    }

    /// A deployment first seen after launch is a silent baseline, even red.
    func testADeploymentAddedLaterIsBaselinedSilently() {
        var watch = primed()
        let both = [Spec(), Spec(key: "booking-sk", title: "Booking SK", verdict: "down", down: ["api"])]
        XCTAssertEqual(watch.update(digest: digest(both), unreachableSince: nil, now: t0 + 15), [])
        XCTAssertEqual(watch.update(digest: digest(both), unreachableSince: nil, now: t0 + 30), [])
    }

    /// With pointers, only those deployments notify, under their own title.
    func testOnlyPointerDeploymentsNotifyUnderTheirTitles() {
        let pointers = [ProdPointer(key: "exampleapp-prod", title: "ExampleApp", tier: "critical", order: 1)]
        let calm = [Spec(), Spec(key: "voke", title: "voke")]
        let red = [Spec(verdict: "down", down: ["api"]), Spec(key: "voke", title: "voke", verdict: "down", down: ["api"])]
        var watch = ProdTransitions()
        _ = watch.update(digest: digest(calm), unreachableSince: nil, pointers: pointers, now: t0)
        let notices = watch.update(digest: digest(red), unreachableSince: nil, pointers: pointers, now: t0 + 15)
        XCTAssertEqual(notices.map(\.title), ["🔴 ExampleApp · API down"])
    }

    /// FiringWatch announced the red while Hlídač was away: adopted, never
    /// repeated, and its recovery comes from here.
    func testAdoptedRedIsNotRepeatedAndRecoversHere() {
        var watch = primed()
        watch.adopt(["exampleapp-prod"])
        XCTAssertEqual(watch.update(digest: digest(Spec(verdict: "down", down: ["api"])), unreachableSince: nil,
                                    now: t0 + 15), [])
        XCTAssertEqual(watch.update(digest: digest(Spec()), unreachableSince: nil, now: t0 + 30).map(\.title),
                       ["✅ ExampleApp prod recovered"])
        // Adopted but already over by the time Hlídač returned: one recovery.
        var over = primed()
        over.adopt(["exampleapp-prod"])
        XCTAssertEqual(over.update(digest: digest(Spec()), unreachableSince: nil, now: t0 + 15).map(\.title),
                       ["✅ ExampleApp prod recovered"])
    }
}
