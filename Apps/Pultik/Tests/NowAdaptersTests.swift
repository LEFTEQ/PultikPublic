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

    /// A todo is due from dueAt − lead and keeps that onset once overdue
    /// (only its severity rises); a milestone has no clock; todos due at the
    /// same instant read as one ×N row.
    func testRipeTodoKeepsItsRipeOnsetWhenOverdue() throws {
        let hour: TimeInterval = 3600
        let todos = [
            NowInputs.Todo(id: 1, project: "exampleapp", title: "overdue", dueAt: now.addingTimeInterval(-hour)),
            NowInputs.Todo(id: 2, project: "exampleapp", title: "later", dueAt: now.addingTimeInterval(3 * hour)),
            NowInputs.Todo(id: 3, project: "exampleapp", title: "long lead", dueAt: now.addingTimeInterval(hour),
                           lead: 86400),
            NowInputs.Todo(id: 4, project: "exampleapp", title: "milestone", dueAt: nil, reason: "milestone"),
            NowInputs.Todo(id: 5, project: "exampleapp", title: "done", status: "done", dueAt: now.addingTimeInterval(-hour)),
            NowInputs.Todo(id: 6, project: "exampleapp", title: "same slot", dueAt: now.addingTimeInterval(-hour)),
        ]
        let read = NowAdapters.ripeTodos(todos, origin: "boards.example.invalid", workspace: "exampleapp", account: "a1", now: now)
        XCTAssertEqual(read.needs.map(\.title), ["overdue", "long lead", "milestone", "same slot"])
        XCTAssertEqual(read.needs[0].onset, .exact(now.addingTimeInterval(-3 * hour)))
        XCTAssertEqual(read.needs.map(\.severity), [.warning, .normal, .normal, .warning])
        XCTAssertEqual(read.needs[1].deadline, now.addingTimeInterval(hour))
        XCTAssertEqual(read.needs[2].onset, .observed(now))
        XCTAssertEqual(read.needs[0].incidentKey, "vitrinka:boards.example.invalid:exampleapp:task:1")

        let queue = NowQueue.build(needs: read.needs, now: now)
        XCTAssertEqual(queue.rows.first?.shape, .series)
        XCTAssertEqual(queue.rows.first?.incidents.map(\.lead.title), ["overdue", "same slot"])
    }

    /// Stale starts seven days after parking, unheld only; hot and fresh
    /// workspaces never enter Now, and a silent box makes the read partial.
    func testStaleWorkspaceDriftsFromSevenDaysAfterParking() {
        let day: TimeInterval = 86400
        func workspace(_ name: String, state: String = "parked", hold: Bool = false, parkedDaysAgo: Double) -> DevboxWorkspace {
            DevboxWorkspace(name: name, project: nil, branch: nil, portBase: nil, created: nil, apps: [], stats: [],
                            memoryBytes: 0, cpuPercent: 0, declaredSources: [], state: state, hold: hold,
                            parkedAt: now.addingTimeInterval(-parkedDaysAgo * day))
        }
        let read = NowAdapters.staleWorkspaces([
            workspace("example-backtest", parkedDaysAgo: 14),
            workspace("build-server-buildkit-2x", hold: true, parkedDaysAgo: 12),
            workspace("exampleapp-journeys", parkedDaysAgo: 1),
            workspace("pultik-copilot-shell", state: "running", parkedDaysAgo: 9),
        ], complete: false, now: now)
        XCTAssertEqual(read.coverage, .partial)
        XCTAssertEqual(read.needs.map(\.incidentKey), ["devbox:c:workspace:example-backtest:stale"])
        XCTAssertEqual(read.needs.first?.onset, .exact(now.addingTimeInterval(-7 * day)))
        XCTAssertEqual(read.needs.first?.verb.destructive, true)
    }

    /// AC 11: a live waiting session waits on you from when it began waiting;
    /// a busy or gone one is no need, a stale snapshot clears nothing, and a
    /// cmux that could not see every surface makes the read partial.
    func testWaitingSessionWaitsOnYouAndAStaleSnapshotClearsNothing() {
        func session(_ id: String, waiting: Bool = true, alive: Bool = true) -> NowInputs.FleetSession {
            NowInputs.FleetSession(id: id, name: "onyx-\(id)", project: "onyx", waiting: waiting, alive: alive,
                                   waitingFor: "input needed", since: now.addingTimeInterval(-3_600))
        }
        let fleet = NowInputs.Fleet(generatedAt: now.addingTimeInterval(-10), complete: true,
                                    sessions: [session("a"), session("b", waiting: false), session("c", alive: false)])
        let read = NowAdapters.sessionsWaiting(fleet, machine: "mac", now: now)
        XCTAssertEqual(read.coverage, .complete)
        XCTAssertEqual(read.needs.map(\.needID), ["session:mac:a"])
        XCTAssertEqual(read.needs.first?.lane, .waitingOnYou)
        XCTAssertEqual(read.needs.first?.waiterRank, .blockedRequest)
        XCTAssertEqual(read.needs.first?.onset, .exact(now.addingTimeInterval(-3_600)))
        XCTAssertEqual(read.needs.first?.target, NowTarget(module: .sessions, objectID: "session:a"))

        let stale = NowInputs.Fleet(generatedAt: now.addingTimeInterval(-NowAdapters.fleetStaleAfter - 1),
                                    complete: true, sessions: [session("a")])
        XCTAssertEqual(NowAdapters.sessionsWaiting(stale, machine: "mac", now: now).coverage, .failed)
        let blind = NowInputs.Fleet(generatedAt: now, complete: false, sessions: [session("a")])
        XCTAssertEqual(NowAdapters.sessionsWaiting(blind, machine: "mac", now: now).coverage, .partial)
    }

    /// eve's approvals view: parked nodes group under their top-level root,
    /// deepest first; each is a waiting-on-you need of that one workflow
    /// incident, starting at first observation, and the unpaginated list is a
    /// complete read.
    func testEveApprovalsGroupByWorkflowAndWaitOnYou() throws {
        let json = """
            {"sessions": [
              {"id": "root", "title": "Review ExampleApp#641", "status": "running", "parentSessionId": null,
               "approvalKind": null, "workflowFlow": "pr_review", "updatedAt": "2026-10-11T07:00:00.123Z",
               "stalled": false, "source": {"repo": "example-org/ExampleApp", "prNumber": 641}},
              {"id": "mid", "title": "subagent", "status": "running", "parentSessionId": "root",
               "approvalKind": "approval", "waitingTool": "create_pr_review",
               "updatedAt": "2026-10-11T07:10:00.000Z", "stalled": false},
              {"id": "leaf", "title": "open the PR", "status": "running", "parentSessionId": "mid",
               "approvalKind": "approval", "waitingTool": "open_pr", "updatedAt": "2026-10-11T07:05:00.000Z",
               "stalled": false},
              {"id": "done", "title": "answered", "status": "done", "parentSessionId": "root",
               "approvalKind": "approval", "updatedAt": "2026-10-11T07:01:00.000Z", "stalled": false}
            ]}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        let sessions = try decoder.decode(EveApprovalsResponse.self, from: Data(json.utf8)).sessions
        let approvals = EveApproval.group(sessions)
        XCTAssertEqual(approvals.map(\.rootID), ["root"])
        XCTAssertEqual(approvals.first?.parked.map(\.id), ["leaf", "mid"])
        XCTAssertEqual(approvals.first?.url.absoluteString, "https://app.assistant.example.invalid/approvals/leaf")

        let read = NowAdapters.eveApprovals(approvals, origin: "eve.test", account: "a", now: now)
        XCTAssertEqual(read.coverage, .complete)
        XCTAssertEqual(Set(read.needs.map(\.incidentKey)), ["eve:eve.test:workflow:root"])
        XCTAssertEqual(read.needs.map(\.needID), ["eve:eve.test:approval:leaf", "eve:eve.test:approval:mid"])
        XCTAssertEqual(read.needs.first?.lane, .waitingOnYou)
        XCTAssertEqual(read.needs.first?.waiterRank, .blockedRequest)
        XCTAssertEqual(read.needs.first?.onset, .observed(now))
        XCTAssertEqual(read.needs.first?.target.objectID, "approval:root")
        XCTAssertEqual(NowAdapters.eveApprovals(nil, origin: "eve.test", account: "a", now: now).coverage, .failed)
    }

    /// eve's ledger carries rows with no flow (`flow: null`, 2026-10-11): the
    /// page still decodes, the need's subtitle is the category alone, and a
    /// repeat of one alert joins its incident instead of taking a row.
    func testEveNotificationWithoutAFlowStillDecodes() throws {
        let json = """
            {"notifications": [
              {"id": 3, "ts": "2026-10-08T12:30:00.000Z", "flow": "priority", "category": "priority",
               "severity": "critical", "title": "Recorder log size", "body": ""},
              {"id": 2, "ts": "2026-10-08T12:00:00.000Z", "flow": null, "category": "priority",
               "severity": "critical", "title": "Recorder log size", "body": ""},
              {"id": 1, "ts": "2026-10-08T11:00:00.000Z", "flow": "pr_review", "category": "general",
               "severity": null, "title": "Review ExampleApp#641", "body": ""}
            ], "nextBefore": null}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        let alerts = try decoder.decode(EveAlertsResponse.self, from: Data(json.utf8)).notifications
        XCTAssertEqual(alerts.map(\.flow), ["priority", nil, "pr_review"])

        let read = NowAdapters.eveNotifications(alerts, lanes: ["priority"], origin: "eve.test", account: "a", now: now)
        XCTAssertEqual(read.needs.map(\.subtitle), ["priority", "priority"])
        XCTAssertEqual(Set(read.needs.map(\.incidentKey)).count, 1)
    }

    /// A stalled approval parked over a week drifts; a live or recent one waits on you.
    func testStalledApprovalOverAWeekDrifts() {
        func approval(_ id: String, stalled: Bool, days: Double) -> EveApproval {
            EveApproval(rootID: id, title: id, flow: nil, repo: nil, prNumber: nil,
                        parked: [.init(id: id, title: id, tool: nil, updatedAt: now.addingTimeInterval(-days * 86_400),
                                       stalled: stalled)])
        }
        let approvals = [approval("old", stalled: true, days: 109), approval("live", stalled: false, days: 109),
                         approval("fresh", stalled: true, days: 1)]
        let lanes = NowAdapters.eveApprovals(approvals, origin: "eve.test", account: "a", now: now).needs.map(\.lane)
        XCTAssertEqual(lanes, [.drifting, .waitingOnYou, .waitingOnYou])
    }
}
