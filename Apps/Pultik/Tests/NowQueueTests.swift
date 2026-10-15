import XCTest
@testable import Pultik

/// The Now queue (copilot shell D6, D12–D15; docs/specs/2026-10-09-now-queue-contracts.md)
/// over the shared dataset (data.md, Thursday Oct 8 2026, 15:12 local).
final class NowQueueTests: XCTestCase {
    private static func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute,
                                                  second: second))!
    }

    private static let now = at(8, 15, 12)
    private static let exampleappProd = "hlidac:hlidac.ops.example.invalid:deployment:exampleapp-prod"

    private func need(_ id: String, incident: String? = nil, _ kind: NowKind, _ lane: NowLane,
                      _ severity: NowSeverity, _ onset: NowOnset, title: String? = nil, displayID: String? = nil,
                      waiter: NowWaiterRank = .other, series: String? = nil) -> NowNeed {
        NowNeed(needID: id, incidentKey: incident ?? id, kind: kind, lane: lane, severity: severity, onset: onset,
                title: title ?? id, displayID: displayID, verb: .open("Open"),
                target: NowTarget(module: .home, objectID: id), waiterRank: waiter, seriesKey: series)
    }

    /// data.md's nine Now items: ExampleApp prod is three needs (the failing jobs
    /// check, Sentry EXAMPLEAPP-API-9Q with its lifetime first-seen, and the
    /// firing alert whose activeAt includes its 15m hold); the reminders are
    /// seven todos due together at 09:00.
    private func at(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Self.at(day, hour, minute, second)
    }

    private func dataset() -> [NowNeed] {
        let reminders = (1...7).map {
            need("vitrinka:exampleapp:task:\(900 + $0):occurrence:0900", incident: "vitrinka:exampleapp:task:\(900 + $0)",
                 .reminder, .due, .warning, .exact(at(8, 9, 0)), series: "vitrinka:exampleapp:due:0900")
        }
        return [
            need("hlidac:exampleapp-prod:check:jobs-stuck", incident: Self.exampleappProd, .deployment, .onFire, .critical,
                 .exact(at(8, 14, 57)), title: "exampleapp-prod elasticsearch-sync has stuck failed jobs"),
            need("hlidac:sentry:EXAMPLEAPP-API-9Q", incident: Self.exampleappProd, .sentryIssue, .onFire, .critical,
                 .firstSeen(at(1, 10, 0)), displayID: "EXAMPLEAPP-API-9Q"),
            need("estate:prometheus:ExampleappProdJobsStuck:deployment=exampleapp-prod", incident: Self.exampleappProd,
                 .firingAlert, .onFire, .critical, .exact(at(8, 14, 57))),
            need("eve:approval:migrations", .eveApproval, .waitingOnYou, .warning, .exact(at(8, 15, 6)),
                 title: "Approve: run migrations on staging?", waiter: .blockedRequest),
            need("fleet:mac:session:brainstorm", .sessionWaiting, .waitingOnYou, .warning, .exact(at(8, 15, 10)),
                 title: "Brainstorm asks you to pick a layout", waiter: .blockedRequest),
            need("github:assistant-service:pr:412:check:CI/test", incident: "github:assistant-service:pr:412", .failedCheck,
                 .waitingOnYou, .warning, .exact(at(8, 15, 8)), title: "CI #8812 failed in test", displayID: "#412",
                 waiter: .ownFailure, series: "github:assistant-service:check:CI/test"),
            need("github:exampleapp:pr:1290:review", incident: "github:exampleapp:pr:1290", .reviewRequested, .waitingOnYou,
                 .normal, .exact(at(8, 14, 12)), title: "Journeys in the company language", displayID: "#1290",
                 waiter: .reviewRequest),
            need("vitrinka:exampleapp:task:1365", .overdueTask, .due, .warning, .exact(at(2, 9, 0)),
                 title: "Post-production deploy: verify signing fix", displayID: "FIX-1365"),
        ] + reminders + [
            need("onyx:example-wildcard:expiry", .expiry, .drifting, .warning, .exact(at(7, 0, 0)),
                 title: "example wildcard SAN cert expires Oct 21"),
            need("estate:prometheus:DiskTrendingLow:host=web-server", .firingAlert, .drifting, .warning,
                 .exact(at(8, 9, 12)), title: "Disk space trending low on web-server"),
        ]
    }

    /// AC1: on fire → waiting → due → drifting, then severity, then age —
    /// inside waiting, an eve or agent request blocked on you beats your own
    /// failed CI, which beats a review; related events share one incident.
    func testDatasetRanksByLaneSeverityWaiterAndAgeIntoNineIncidents() throws {
        let queue = NowQueue.build(needs: dataset().reversed(), now: Self.now)

        XCTAssertEqual(queue.rows.map(\.key), [
            Self.exampleappProd,
            "eve:approval:migrations",
            "fleet:mac:session:brainstorm",
            "github:assistant-service:pr:412",
            "github:exampleapp:pr:1290",
            "vitrinka:exampleapp:task:1365",
            "series:due:reminder:vitrinka:exampleapp:due:0900",
            "onyx:example-wildcard:expiry",
            "estate:prometheus:DiskTrendingLow:host=web-server",
        ])
        XCTAssertEqual(queue.lanes.map(\.incidents), [1, 4, 2, 2])
        XCTAssertEqual(queue.lanes.map(\.needs), [3, 4, 8, 2])
        XCTAssertEqual(queue.incidentCount, 9)
        XCTAssertEqual(queue.needCount, 17)

        // The check, the Sentry issue and the alert are one deployment row;
        // the issue's lifetime first-seen never backdates the bar.
        let prod = try XCTUnwrap(queue.incident(Self.exampleappProd))
        XCTAssertEqual(prod.needs.map(\.kind), [.firingAlert, .deployment, .sentryIssue])
        XCTAssertEqual(prod.severity, .critical)
        XCTAssertEqual(prod.onset, .exact(Self.at(8, 14, 57)))
        // Seven reminders due together are one ×7 problem.
        XCTAssertEqual(queue.rows[6].shape, .series)
        XCTAssertEqual(queue.rows[6].incidents.count, 7)
    }

    /// The incident-morning flood (31 needs at 10:05).
    private func flood() -> [NowNeed] {
        let onFire = [
            need("hlidac:exampleapp-prod:check", incident: "deploy:exampleapp-prod", .deployment, .onFire, .critical,
                 .exact(at(8, 9, 38))),
            need("estate:exampleapp-prod:alert", incident: "deploy:exampleapp-prod", .firingAlert, .onFire, .critical,
                 .exact(at(8, 9, 38))),
            need("hlidac:sentry:EXAMPLEAPP-API-9Q", incident: "deploy:exampleapp-prod", .sentryIssue, .onFire, .critical,
                 .observed(at(8, 9, 41))),
            need("hlidac:eve-exampleapp:check", incident: "deploy:eve-exampleapp", .deployment, .onFire, .critical,
                 .observed(at(8, 9, 44))),
            need("eve:notification:44", incident: "deploy:eve-exampleapp", .eveNotification, .onFire, .critical,
                 .exact(at(8, 9, 44))),
        ] + [(8, 0), (8, 30), (9, 0)].map { hour, minute in
            need("estate:critical:\(hour)\(minute)", .firingAlert, .onFire, .critical, .exact(at(8, hour, minute)))
        }
        let sessions = [at(8, 10, 3), at(8, 10, 4), at(8, 10, 4, 30), at(8, 10, 5)].enumerated().map { index, onset in
            need("fleet:session:\(index)", .sessionWaiting, .waitingOnYou, .warning, .exact(onset), waiter: .blockedRequest)
        }
        let failing = [(412, 8, 12), (415, 8, 40), (418, 9, 0), (420, 9, 10), (421, 9, 20), (425, 9, 30)].map {
            need("github:assistant-service:pr:\($0.0):check:CI/test", incident: "github:assistant-service:pr:\($0.0)",
                 .failedCheck, .waitingOnYou, .warning, .exact(at(8, $0.1, $0.2)), displayID: "#\($0.0)",
                 waiter: .ownFailure, series: "github:assistant-service:check:CI/test")
        }
        let waiting = [need("eve:approval", .eveApproval, .waitingOnYou, .warning, .exact(at(8, 9, 59)),
                            waiter: .blockedRequest)]
            + sessions + failing + [
                need("github:assistant-service:pr:430:check:CI/lint", incident: "github:assistant-service:pr:430", .failedCheck,
                     .waitingOnYou, .warning, .exact(at(8, 9, 35)), displayID: "#430", waiter: .ownFailure,
                     series: "github:assistant-service:check:CI/lint"),
            ] + [at(8, 7, 5), at(8, 9, 5), at(8, 9, 30)].enumerated().map { index, onset in
                need("github:review:\(index)", .reviewRequested, .waitingOnYou, .normal, .exact(onset),
                     waiter: .reviewRequest)
            }
        let due = (3...7).map { day in
            need("vitrinka:task:\(day)", .overdueTask, .due, .critical, .exact(at(day, 9, 0)))
        } + (1...2).map {
            need("vitrinka:todo:\($0)", .reminder, .due, .normal, .exact(at(8, 9, 0)), series: "vitrinka:due:0900")
        }
        return onFire + waiting + due + [need("devbox:a:workspace:example-backtest:stale", .staleWorkspace, .drifting,
                                              .normal, .exact(at(1, 9, 0)))]
    }

    /// AC2: past a lane's first rows same-kind needs fold into one counted
    /// row; on fire and critical never fold; a ×N row forms only where the
    /// check identity matches.
    func testFloodFoldsByKindButNeverOnFireOrCritical() throws {
        let queue = NowQueue.build(needs: flood(), now: Self.at(8, 10, 5))
        XCTAssertEqual(queue.needCount, 31)
        XCTAssertEqual(queue.lanes.map(\.incidents), [5, 10, 6, 1])
        XCTAssertEqual(queue.lanes.map(\.needs), [8, 15, 7, 1])
        XCTAssertEqual(queue.lanes.map(\.folded), [0, 5, 0, 0])

        // On fire: five rows past the lead rows, two deployments of one kind, no fold.
        let onFire = queue.rows.filter { $0.lane == .onFire }
        XCTAssertEqual(onFire.map(\.shape), Array(repeating: .incident, count: 5))

        // Waiting: the lead three stand; two more sessions and three reviews
        // fold; CI/test on six PRs is one ×6 row; CI/lint is its own row.
        let waiting = queue.rows.filter { $0.lane == .waitingOnYou }
        XCTAssertEqual(waiting.map(\.shape), [.incident, .incident, .incident, .fold, .series, .incident, .fold])
        XCTAssertEqual(waiting[3].incidents.map(\.key), ["fleet:session:2", "fleet:session:3"])
        XCTAssertEqual(waiting[4].incidents.map(\.lead.displayID), ["#412", "#415", "#418", "#420", "#421", "#425"])
        XCTAssertEqual(waiting[5].lead.lead.displayID, "#430")
        XCTAssertEqual(waiting[6].heroCount, 3)

        // Due: five critical overdue tasks never fold, even past the lead.
        let due = queue.rows.filter { $0.lane == .due }
        XCTAssertEqual(due.map(\.shape), [.incident, .incident, .incident, .incident, .incident, .series])

        // A fold expands in place, its members tagged with it.
        let expanded = queue.visible(expanded: [waiting[3].key]).filter { $0.lane == .waitingOnYou }
        XCTAssertEqual(expanded.map(\.key)[3...4], ["fleet:session:2", "fleet:session:3"])
        XCTAssertEqual(expanded[3].parentKey, waiting[3].key)
        XCTAssertEqual(expanded.count, 8)
    }

    /// AC3: a re-rank keeps the selection on its incident and child; a
    /// resolved selection leaves a tombstone Return cannot act on, and the
    /// next arrow lands on the nearest surviving neighbour of the old order.
    func testSelectionSurvivesReRankAndResolvesToATombstone() throws {
        let before = NowQueue.build(needs: dataset(), now: Self.now)
        let sentry = "hlidac:sentry:EXAMPLEAPP-API-9Q"
        let prod = NowSelection(incidentKey: Self.exampleappProd, needID: sentry)

        // A new emergency outranks ExampleApp prod: the cursor stays on the object.
        let urgent = need("hlidac:vitrinka:down", .deployment, .onFire, .emergency, .exact(Self.at(8, 15, 11)))
        let reRanked = NowQueue.build(needs: dataset() + [urgent], now: Self.now)
        XCTAssertEqual(reRanked.rows.first?.key, "hlidac:vitrinka:down")
        let kept = prod.refreshed(from: before, to: reRanked)
        XCTAssertEqual(kept, prod)
        XCTAssertEqual(kept.returnTarget(in: reRanked)?.objectID, sentry)
        XCTAssertEqual(kept.moved(.up, in: reRanked)?.incidentKey, "hlidac:vitrinka:down")

        // The selected child resolves, its siblings remain: still selected.
        let childGone = NowQueue.build(needs: dataset().filter { $0.needID != sentry }, now: Self.now)
        let stillProd = prod.refreshed(from: before, to: childGone)
        XCTAssertFalse(stillProd.isTombstone)
        XCTAssertTrue(stillProd.childResolved(in: childGone))

        // PR #412 resolves, then the review after it: a tombstone that never
        // moves and Return cannot use.
        let pr412 = NowSelection(incidentKey: "github:assistant-service:pr:412")
        let resolved = NowQueue.build(needs: dataset().filter { !$0.needID.hasPrefix("github:assistant-service:pr:412") },
                                      now: Self.now)
        let tombstone = pr412.refreshed(from: before, to: resolved)
        XCTAssertTrue(tombstone.isTombstone)
        XCTAssertEqual(tombstone.incidentKey, "github:assistant-service:pr:412")
        XCTAssertNil(tombstone.returnTarget(in: resolved))
        let laterStill = NowQueue.build(needs: dataset().filter { !$0.needID.hasPrefix("github:") }, now: Self.now)
        XCTAssertEqual(tombstone.refreshed(from: resolved, to: laterStill), tombstone)

        XCTAssertEqual(tombstone.moved(.down, in: laterStill)?.incidentKey, "vitrinka:exampleapp:task:1365")
        XCTAssertEqual(tombstone.moved(.up, in: laterStill)?.incidentKey, "fleet:mac:session:brainstorm")
    }
}
