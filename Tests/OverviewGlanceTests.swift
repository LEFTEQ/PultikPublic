import XCTest
@testable import Pultik

final class OverviewGlanceTests: XCTestCase {
    private struct Row: Equatable {
        let title: String
        let reason: String
    }

    private let gib = DevboxGlance.gib

    func testVitrinkaCountsAndTopRowsRankAttention() {
        let today = [
            Row(title: "a", reason: "in progress"),
            Row(title: "b", reason: "due now"),
            Row(title: "c", reason: "overdue"),
            Row(title: "d", reason: "needs you"),
            Row(title: "e", reason: "due now"),
            Row(title: "f", reason: "mentioned"),
        ]
        let glance = VitrinkaGlance(today: today, reason: \.reason, liveQuestions: [3, 0, 2], elsewhere: [])

        XCTAssertEqual([glance.needsYou, glance.overdue, glance.dueNow, glance.inProgress], [1, 1, 2, 1])
        XCTAssertEqual(glance.openQuestions, 5)
        XCTAssertEqual(glance.top.map(\.title), ["d", "c", "b"])
    }

    func testVitrinkaElsewhereCountsOnlyOtherWorkspacesAttention() {
        let selected = [Row(title: "mine", reason: "needs you")]
        let others = [
            [Row(title: "x", reason: "overdue"), Row(title: "y", reason: "assigned to you")],
            [Row(title: "z", reason: "due now")],
        ]
        let glance = VitrinkaGlance(today: selected, reason: \.reason, liveQuestions: [], elsewhere: others)
        XCTAssertEqual(glance.elsewhere, 2)

        let quiet = VitrinkaGlance(today: selected, reason: \.reason, liveQuestions: [],
                                   elsewhere: [[Row(title: "m", reason: "mentioned")]])
        XCTAssertNil(quiet.elsewhere)
    }

    func testDevboxHeadroomStaleAndHeld() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let glance = DevboxGlance(
            summary: summary(total: 64, available: 22, floor: 8),
            workspaces: [
                workspace("light", state: "running", memory: 1 * gib),
                workspace("heavy", state: "running", memory: 5 * gib, hold: true),
                workspace("old", state: "parked", parkedAt: now.addingTimeInterval(-8 * day)),
                workspace("edge", state: "parked", parkedAt: now.addingTimeInterval(-7 * day)),
                workspace("unknown", state: "parked", parkedAt: nil, hold: true),
                // Held and old: gc --retire-stale never clears it, so not stale.
                workspace("pinned", state: "parked", parkedAt: now.addingTimeInterval(-30 * day), hold: true),
            ],
            now: now
        )

        XCTAssertEqual(glance.headroomBytes, 14 * gib)
        XCTAssertEqual(glance.memoryUsedBytes, 42 * gib)
        XCTAssertEqual(glance.running.map(\.name), ["heavy", "light"])
        XCTAssertEqual(glance.parked, 4)
        XCTAssertEqual(glance.stale, 1)
        XCTAssertEqual(glance.held, 3)
    }

    func testDevboxAlertsFireOnlyPastEachThreshold() {
        let atThreshold = DevboxGlance(
            summary: summary(pressure: 5, cpus: 8, load1: 8, swapUsedGB: 0.5, ports: (80, 100)),
            workspaces: []
        )
        XCTAssertEqual(atThreshold.alerts, [])

        let past = DevboxGlance(
            summary: summary(pressure: 5.1, cpus: 8, load1: 8.8, swapUsedGB: 0.75, ports: (81, 100)),
            workspaces: []
        )
        XCTAssertEqual(past.alerts, [
            .pressure(percent: 5.1), .swap(bytes: 0.75 * gib), .load(perCore: 1.1), .slots(used: 81, total: 100),
        ])
        // Swap is a gauge on the widget; the banner leaves it out.
        XCTAssertEqual(past.bannerAlerts, [
            .pressure(percent: 5.1), .load(perCore: 1.1), .slots(used: 81, total: 100),
        ])

        let noCores = DevboxGlance(summary: summary(cpus: 0, load1: 40), workspaces: [])
        XCTAssertNil(noCores.loadPerCore)
        XCTAssertEqual(noCores.alerts, [])
    }

    func testCIMatchesLanesAndFooterTotals() {
        let job = CIJob(org: "example-org", repo: "ExampleApp", lane: "exampleapp-ci", workflow: "ci",
                        jobName: "test", runURL: nil, since: nil)
        let board = CILaneBoard(
            lanes: [
                CILane(name: "exampleapp-ci", backend: "docker", trustGroup: "firefly", up: true,
                       tier: 0, kind: "ci", queued: 2, jobs: [job, job]),
                CILane(name: "kvm-macos", backend: "kvm", trustGroup: "firefly", up: false,
                       queued: 1, jobs: []),
            ],
            elsewhere: [job], elsewhereQueued: 1
        )
        let repos = [
            RepoStatus(slug: "a/one", runs: [run(status: "completed", conclusion: "failure"),
                                             run(status: "in_progress", conclusion: nil)]),
            RepoStatus(slug: "a/two", runs: [run(status: "completed", conclusion: "timed_out")],
                       deploys: [deploy(state: "error"), deploy(state: "queued")]),
        ]
        let glance = CIGlance(board: board, repos: repos)

        XCTAssertEqual(glance.running, 3)
        XCTAssertEqual(glance.queued, 4)
        XCTAssertEqual(glance.lanesDown, 1)
        XCTAssertEqual(glance.failedRuns, 3)
        XCTAssertEqual(glance.runningRuns, 2)
        // A running run is also a lane job: one source, never the sum.
        XCTAssertEqual(glance.runningCount(lanesReport: true), 3)
        XCTAssertEqual(glance.runningCount(lanesReport: false), 2)
        XCTAssertFalse(glance.githubUnreachable)
        XCTAssertTrue(CIGlance(board: board, repos: [RepoStatus(slug: "a/x", error: "offline")]).githubUnreachable)
    }

    func testFiringAlertsBecomeOneRowPerRuleCriticalFirst() throws {
        // Live shape of Prometheus's GET /api/v1/alerts (2026-09-27), trimmed.
        func alert(_ name: String, _ severity: String, _ summary: String, state: String = "firing",
                   at: String, extra: String = "") -> String
        {
            #"{"labels":{"alertname":"\#(name)","severity":"\#(severity)"\#(extra)},"annotations":{"summary":"\#(summary)","description":"d"},"state":"\#(state)","activeAt":"\#(at)","value":"1e+00"}"#
        }
        let alerts = [
            alert("Watchdog", "none", "heartbeat", at: "2026-09-25T05:51:03.717905439Z"),
            alert("DiskSpaceWarning", "warning", "Low disk space on build-vps", at: "2026-09-27T08:00:00Z"),
            alert("DiskSpaceWarning", "warning", "Low disk space on web-server", at: "2026-09-27T09:00:00.5Z"),
            alert("ContainerMemoryAtLimit", "critical", "litellm over 97%", at: "2026-09-27T07:00:00Z",
                  extra: #","app":"eve","environment":"production""#),
            // Newer, but a warning: it must not speak for the red row.
            alert("ContainerMemoryAtLimit", "warning", "sidecar over 97%", at: "2026-09-27T11:00:00Z"),
            alert("RedisGrowth", "info", "redis", at: "2026-09-27T10:00:00Z"),
            alert("SlowSoon", "critical", "pending", state: "pending", at: "2026-09-27T10:00:00Z"),
        ]
        let body = #"{"status":"success","data":{"alerts":[\#(alerts.joined(separator: ","))]}}"#
        let decoded = try XCTUnwrap(FiringAlert.decode(Data(body.utf8), source: .prometheus))
        XCTAssertEqual(decoded.count, 7)
        XCTAssertNotNil(decoded[0].activeAt, "nanosecond timestamps must parse")

        // Watchdog, info and pending never show; the same rule on two hosts
        // is one row led by its newest instance; critical outranks newer.
        let glance = AlertGlance(decoded)
        XCTAssertEqual(glance.rows.map(\.name), ["ContainerMemoryAtLimit", "DiskSpaceWarning"])
        XCTAssertEqual(glance.rows[0].title, "litellm over 97%")
        XCTAssertEqual(glance.rows[0].context, "eve · production")
        XCTAssertEqual(glance.rows[0].more, 1)
        XCTAssertEqual(glance.rows[1].title, "Low disk space on web-server")
        XCTAssertEqual(glance.rows[1].more, 1)
        XCTAssertEqual(glance.critical, 1)
        XCTAssertNil(FiringAlert.decode(Data(#"{"status":"error"}"#.utf8), source: .loki))
    }

    func testSemaforOverviewBecomesTheDayLines() throws {
        // Live shape of semafor's GET /api/v1/overview (2026-09-27), trimmed:
        // 13:40 in Prague, so hours 14..23 are still ahead.
        let hours = (0..<24).map { #"{"hour":\#($0),"jobs":\#($0 <= 13 ? $0 + 1 : 0),"repos":[]}"# }
        let body = """
        {"at":"2026-09-27T11:40:02Z","tz":"Europe/Prague","day":"2026-09-27","jobs":1712,
         "yesterday_same_time":1507,"queue":{"p50":3.35,"p95":412.2},"over_300s_share":0.071,
         "hours":[\(hours.joined(separator: ","))],"repos":[],"days":[],"recorded_since":null}
        """
        let glance = CIThroughputGlance(try XCTUnwrap(CIThroughput.decode(Data(body.utf8))))
        XCTAssertEqual(glance.wait, "wait p50 3s · p95 6m52s · 7.1% > 5m")
        XCTAssertTrue(glance.waitSlow)
        XCTAssertEqual(glance.delta, "+14%")
        XCTAssertEqual(glance.hours, Array(1...14))

        // Before the day's first job: no wait line, and no comparison
        // against an empty yesterday.
        let quiet = #"{"at":"2026-09-27T22:05:00Z","tz":"Europe/Prague","jobs":0,"yesterday_same_time":0,"queue":null,"over_300s_share":null,"hours":[]}"#
        let empty = CIThroughputGlance(try XCTUnwrap(CIThroughput.decode(Data(quiet.utf8))))
        XCTAssertNil(empty.wait)
        XCTAssertFalse(empty.waitSlow)
        XCTAssertNil(empty.delta)
    }

    func testSemaforAdmissionBecomesTheDockerPoolWithItsBestRankedHead() throws {
        // Live shape of semafor's GET /api/v1/admission (2026-09-26): the
        // Docker ordinary pool is partition "", the bastion guests "kvm".
        let body = """
        {"at":"2026-09-26T08:03:47.371000051Z","observed_at":"2026-09-26T08:03:41Z","source":"prometheus",
         "partitions":[{"name":"kvm","budget_mib":98304,"reserved_mib":32768,"slots_used":1,"slots_max":4},
                       {"name":"","budget_mib":96256,"reserved_mib":63488,"slots_used":18,"slots_max":32}],
         "lanes":[{"lane":"onyx-ci","backend":"docker","partition":"","running":0,"waiting":1,"head":true,"reserved_mib":2048,"refusals_15m":[]},
                  {"lane":"exampleapp-web","backend":"docker","partition":"","running":2,"waiting":3,"head":true,"reserved_mib":12288,"refusals_15m":[{"reason":"fifo","count":4}]},
                  {"lane":"vitrinka-ci","backend":"docker","partition":"","running":1,"waiting":0,"head":true,"reserved_mib":3072,"refusals_15m":[{"reason":"mem_budget","count":9}]},
                  {"lane":"exampleapp-bastion","backend":"kvm","partition":"kvm","running":1,"waiting":1,"head":true,"reserved_mib":32768,"refusals_15m":[]}]}
        """
        let lanes = [
            CILane(name: "onyx-ci", backend: "docker", trustGroup: "firefly", up: true, tier: 3, kind: "ci", queued: 1, jobs: []),
            CILane(name: "exampleapp-web", backend: "docker", trustGroup: "firefly", up: true, tier: 0, kind: "e2e", queued: 3, jobs: []),
        ]
        let admission = try XCTUnwrap(SemaforAdmission.decode(Data(body.utf8)))
        let pool = try XCTUnwrap(admission.pool(lanes: lanes))

        // Stale head flags (a lane that waits no more, the KVM pool) never
        // win; of two live ones the better tier does.
        XCTAssertEqual(pool.head, CIPoolHead(lane: "exampleapp-web", tier: 0, kind: "e2e", waiting: 3))
        XCTAssertEqual([pool.slotsUsed, pool.slotsMax, pool.reservedMiB, pool.budgetMiB], [18, 32, 63488, 96256])
        XCTAssertEqual(pool.bastion, CIPartitionLoad(slotsUsed: 1, slotsMax: 4, reservedMiB: 32768, budgetMiB: 98304))
        // Only lanes still waiting explain a stuck queue: vitrinka-ci's
        // refusals are history.
        XCTAssertEqual(pool.refusals, [CIRefusal(reason: "fifo", count: 4)])

        let glance = CIPoolGlance(pool: pool, now: try XCTUnwrap(pool.observedAt).addingTimeInterval(60))
        XCTAssertEqual(glance.slots, "18/32 slots")
        XCTAssertEqual(glance.memory, "62/94 GiB")
        XCTAssertEqual(glance.head, "exampleapp-web · tier 0 · e2e")
        XCTAssertFalse(glance.full)
        XCTAssertFalse(glance.stale)
        XCTAssertTrue(CIPoolGlance(pool: pool, now: pool.observedAt!.addingTimeInterval(600)).stale)

        var full = pool
        full.slotsUsed = 32
        full.head = nil
        XCTAssertTrue(CIPoolGlance(pool: full).full)
        XCTAssertNil(CIPoolGlance(pool: full).head)
        // No Docker pool exported yet: no line, not a zero pool.
        let empty = try XCTUnwrap(SemaforAdmission.decode(Data(#"{"observed_at":null,"partitions":[],"lanes":[]}"#.utf8)))
        XCTAssertNil(empty.pool(lanes: lanes))
    }

    func testEstateTreatsUnansweredProbesAsUnknown() {
        let glance = EstateGlance(services: [
            ServiceStatus(name: "a", probe: "https://a", up: true, latencySeconds: 0.1),
            ServiceStatus(name: "b", probe: "https://b", up: true, latencySeconds: 0.3),
            ServiceStatus(name: "c", probe: "https://c", up: false, latencySeconds: 5),
            ServiceStatus(name: "d", probe: "https://d", up: nil, latencySeconds: nil),
        ])

        XCTAssertEqual(glance.total, 4)
        XCTAssertEqual(glance.up, 2)
        XCTAssertEqual(glance.unknown, 1)
        XCTAssertEqual(glance.down.map(\.name), ["c"])
        XCTAssertEqual(glance.medianLatencySeconds ?? 0, 0.2, accuracy: 1e-9)
    }

    // MARK: - Fixtures

    private func summary(
        total: Double = 64, available: Double = 32, floor: Int = 8, pressure: Double = 0,
        cpus: Int = 16, load1: Double = 1, swapUsedGB: Double = 0, ports: (Int, Int)? = nil
    ) -> DevboxOverviewSummary {
        DevboxOverviewSummary(
            identitySlots: 0, targetHot: 0, hotCeiling: 0, claimed: 0, running: 0,
            identities: ports.map { DevboxOverviewIdentities(saved: 10, runtimeLeases: 3,
                                                             portsUsed: $0.0, portCapacity: $0.1) },
            parked: 0, floorGB: floor, pressureSome: pressure, pressureFull: 0,
            cpus: cpus, load1: load1, memoryTotalBytes: total * gib,
            memoryAvailableBytes: available * gib,
            swapTotalBytes: 4 * gib, swapFreeBytes: (4 - swapUsedGB) * gib
        )
    }

    private func workspace(
        _ name: String, state: String, memory: Double = 0, parkedAt: Date? = nil, hold: Bool = false
    ) -> DevboxWorkspace {
        DevboxWorkspace(
            name: name, project: nil, branch: nil, portBase: nil, created: nil, apps: [],
            stats: [], memoryBytes: memory, cpuPercent: 0, declaredSources: [],
            state: state, hold: hold, parkedAt: parkedAt
        )
    }

    private func run(status: String, conclusion: String?) -> WorkflowRun {
        WorkflowRun(id: 1, name: nil, headBranch: nil, status: status, conclusion: conclusion,
                    htmlUrl: "https://github.com", createdAt: Date(), updatedAt: Date())
    }

    private func deploy(state: String) -> DeployInfo {
        DeployInfo(deployment: Deployment(id: 1, environment: "prod", ref: "main", createdAt: Date()),
                   state: state, url: nil)
    }
}
