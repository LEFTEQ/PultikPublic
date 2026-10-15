import XCTest
@testable import Pultik

/// One devbox over several guests (spec 2026-09-25, never summed since
/// 2026-10-14): discovery, the primary box's own figures, the per-box lines
/// and the row tags.
final class DevboxBoxesTests: XCTestCase {
    private static let gib = DevboxGlance.gib
    private let boxA = DevboxEndpoint(name: "a", sshAlias: "devops", host: "192.0.2.11", port: 2222, state: "active")
    private let boxB = DevboxEndpoint(name: "b", sshAlias: "devops-b", host: "192.0.2.11", port: 2223, state: "drain")

    private func candidates(_ rows: String) -> [DevboxDiscovery.Candidate]? {
        DevboxDiscovery.candidates(fromBoxesJSON: Data("""
        {"v":3,"ok":true,"verb":"boxes","data":{"boxes":[\(rows)],"registry":"/opt/devbox/boxes.yaml"},"diagnostics":[],"next":[]}
        """.utf8))
    }

    private func summary(running: Int, parked: Int, cpus: Int, cpu: Double, totalGB: Double, availableGB: Double,
                         disk: (used: Double, total: Double)? = nil) -> DevboxOverviewSummary {
        DevboxOverviewSummary(
            identitySlots: 0, targetHot: 0, hotCeiling: 0, claimed: running, running: running,
            identities: nil, parked: parked, floorGB: 8, pressureSome: 0, pressureFull: 0,
            cpus: cpus, load1: 1, cpuUsagePercent: cpu,
            diskTotalBytes: disk.map { $0.total * Self.gib }, diskUsedBytes: disk.map { $0.used * Self.gib },
            memoryTotalBytes: totalGB * Self.gib, memoryAvailableBytes: availableGB * Self.gib,
            swapTotalBytes: 0, swapFreeBytes: 0
        )
    }

    private func snapshot(_ box: DevboxEndpoint, _ summary: DevboxOverviewSummary, rows: [String]) -> DevboxSnapshot {
        DevboxSnapshot(endpoint: box, generated: nil, workspaces: rows.map {
            DevboxWorkspace(name: $0, project: nil, branch: nil, portBase: nil, created: nil, apps: [],
                            stats: [], memoryBytes: 0, cpuPercent: 0, declaredSources: [])
        }, summary: summary)
    }

    func testDiscoveryPollsEveryBoxButOffAndReadsHostAndPortFromSSHConfig() throws {
        let found = try XCTUnwrap(candidates("""
        {"name":"a","host":"build-server","ssh":"devops","state":"active","reachable":true,"headroom":{"box":"a"}},
        {"name":"b","host":"app-server","ssh":"devops-b","state":"off"},
        {"name":"d","host":"x","ssh":"devops-d","state":"drain","reachable":false,"error":"timeout","fix":"ssh x"}
        """))
        XCTAssertEqual(found.map(\.name), ["a", "d"])
        let many = (1 ... 10).map { #"{"name":"x\#($0)","ssh":"devops","state":"active"}"# }
        XCTAssertEqual(candidates(many.joined(separator: ","))?.count, DevboxDiscovery.boxLimit)
        let endpoint = DevboxDiscovery.endpoint(
            for: found[0], sshConfig: "host devops\nuser devbox\nhostname 192.0.2.11\nport 2222\nidentityfile ~/.ssh/id\n")
        XCTAssertEqual(endpoint, boxA)
        XCTAssertEqual(endpoint?.destination, "devbox@192.0.2.11")
    }

    func testThePrimaryBoxLeadsAndEveryBoxKeepsItsState() throws {
        let found = try XCTUnwrap(candidates("""
        {"name":"a","ssh":"devops","state":"active"},
        {"name":"b","ssh":"devops-b","state":"drain"},
        {"name":"portal","ssh":"devops-portal","state":"off","primary":false},
        {"name":"c","ssh":"devops-c","state":"active","primary":true}
        """))
        XCTAssertEqual(found.map(\.name), ["c", "a", "b"])
        XCTAssertEqual(found.map(\.state), ["active", "active", "drain"])
        let endpoint = DevboxDiscovery.endpoint(for: found[0], sshConfig: "hostname 192.0.2.11\nport 2225\n")
        XCTAssertEqual(endpoint, .fallback)
        XCTAssertEqual(endpoint?.isPrimary, true)
    }

    func testDiscoveryRefusesAnythingThatCouldBecomeAnSSHOption() {
        XCTAssertEqual(candidates("""
        {"name":"a","ssh":"-oProxyCommand=sh","state":"active"},
        {"name":"b","ssh":"devops;rm","state":"active"},
        {"name":"c d","ssh":"devops","state":"active"},
        {"name":"e","ssh":"devops-e","state":"active"}
        """)?.map(\.name), ["e"])
        let candidate = DevboxDiscovery.Candidate(name: "e", sshAlias: "devops-e")
        for config in ["hostname -oProxyCommand=x\nport 22", "hostname 192.0.2.11 x\nport 22",
                       "hostname 192.0.2.11\nport 22x", "hostname 192.0.2.11\nport 70000", "port 22"] {
            XCTAssertNil(DevboxDiscovery.endpoint(for: candidate, sshConfig: config), config)
        }
    }

    func testAnOlderCLIOrAnEmptyRegistryKeepsTheLastGoodListElseTodaysEndpoint() {
        let unknownVerb = Data("""
        {"v":3,"ok":false,"verb":"","diagnostics":[{"code":"CLI_UNKNOWN_VERB","severity":"error"}],"next":["devbox --help"]}
        """.utf8)
        XCTAssertNil(DevboxDiscovery.candidates(fromBoxesJSON: unknownVerb))
        XCTAssertNil(DevboxDiscovery.candidates(fromBoxesJSON: Data("ssh: connect timed out".utf8)))
        XCTAssertNil(candidates(#"{"name":"a","ssh":"devops","state":"off"}"#))
        XCTAssertEqual(DevboxDiscovery.resolve(discovered: nil, previous: nil), [.fallback])
        XCTAssertEqual(DevboxDiscovery.resolve(discovered: nil, previous: [.fallback, boxB]), [.fallback, boxB])
        XCTAssertEqual(DevboxDiscovery.resolve(discovered: [boxB], previous: [.fallback]), [boxB])
    }

    func testOneBoxPassesItsOwnSummaryThroughAndTagsItsRows() {
        let own = summary(running: 12, parked: 48, cpus: 48, cpu: 33, totalGB: 84, availableGB: 32)
        let estate = DevboxEstate(boxes: [.fallback], snapshots: [snapshot(.fallback, own, rows: ["demo"])])
        XCTAssertEqual(estate.summary?.shortLabel, own.shortLabel)
        XCTAssertEqual(estate.summary?.boxes, [])
        XCTAssertNil(estate.summary?.box)
        let glance = DevboxGlance(summary: own, workspaces: estate.workspaces)
        XCTAssertEqual(glance.boxes, [])
        XCTAssertNil(glance.box)
        XCTAssertEqual(estate.workspaces.map(\.box), [.fallback])
        XCTAssertEqual(estate.workspaces.map(\.id), ["c/demo"])
    }

    func testThePrimaryBoxsOwnFiguresLeadAndEveryOtherBoxIsALineNeverASum() throws {
        let c = summary(running: 1, parked: 2, cpus: 64, cpu: 12, totalGB: 124, availableGB: 100, disk: (90, 1536))
        let a = summary(running: 3, parked: 10, cpus: 48, cpu: 50, totalGB: 84, availableGB: 24, disk: (300, 500))
        // b sits 2G below its floor: its own line says so, c's gauges do not.
        let b = summary(running: 2, parked: 5, cpus: 16, cpu: 10, totalGB: 48, availableGB: 6, disk: (100, 200))
        let estate = DevboxEstate(boxes: [.fallback, boxA, boxB],
                                  snapshots: [snapshot(boxB, b, rows: ["web"]), snapshot(boxA, a, rows: ["api", "ops"]),
                                              snapshot(.fallback, c, rows: ["new"])])
        let own = try XCTUnwrap(estate.summary)
        XCTAssertEqual(own.box, "c")
        XCTAssertEqual(own.running, 1)
        XCTAssertEqual(own.diskTotalBytes, 1536 * Self.gib)
        XCTAssertEqual(own.pressure, .normal)
        let glance = DevboxGlance(summary: own, workspaces: estate.workspaces)
        XCTAssertEqual(glance.cores, 64)
        XCTAssertEqual(glance.cpuPercent, 12)
        XCTAssertEqual(glance.box?.title, "box c · primary")
        XCTAssertEqual(glance.boxes.map(\.title), ["box a", "box b · draining"])
        XCTAssertEqual(glance.boxes.map { $0.figure(workspaces: glance.workspacesByBox[$0.name] ?? 0) },
                       ["16G free · 2 ws", "\u{2212}2.0G free · 1 ws"])
        XCTAssertEqual(glance.boxes.map(\.isAlerting), [false, true])
        XCTAssertEqual(glance.boxes[1].help(workspaces: 1, primary: "c"),
                       "Box b drains: no new workspaces land here; 1 still to move (devbox move <ws> --to c)")
        XCTAssertEqual(glance.boxes[1].help(workspaces: 0, primary: "c"), "Box b is drained — its registry row can go off")
        XCTAssertEqual(estate.workspaces.map(\.id), ["c/new", "a/api", "a/ops", "b/web"])
        // The pile is c's own too: a's held rows are a's line's, not c's strip's.
        var rows = estate.workspaces
        rows[1].hold = true
        XCTAssertEqual(DevboxGlance(summary: own, workspaces: rows).held, 0)
        XCTAssertEqual(DevboxGlance(summary: own, workspaces: rows).running.map(\.id), ["c/new"])
    }

    func testASilentPrimaryHandsTheStripToTheFirstBoxThatAnsweredAndNeverBlanksTheOthers() throws {
        let b = summary(running: 2, parked: 5, cpus: 16, cpu: 10, totalGB: 48, availableGB: 39)
        let estate = DevboxEstate(boxes: [.fallback, boxB], snapshots: [snapshot(boxB, b, rows: ["web"])])
        let own = try XCTUnwrap(estate.summary)
        XCTAssertEqual(own.box, "b")
        XCTAssertEqual(own.running, 2)
        let glance = DevboxGlance(summary: own, workspaces: estate.workspaces)
        XCTAssertEqual(glance.box?.title, "box b · draining")
        XCTAssertEqual(glance.boxes.map(\.title), ["box c · primary"])
        XCTAssertEqual(glance.boxes.map { $0.figure(workspaces: 0) }, ["silent"])
        XCTAssertEqual(glance.boxes.map(\.isAlerting), [true])
        // A drain still moves to the registry's primary, not the strip's box.
        XCTAssertEqual(glance.primaryBox, "c")
        XCTAssertEqual(estate.workspaces.map { $0.box?.name }, ["b"])

        let dark = DevboxEstate(boxes: [.fallback, boxB], snapshots: [])
        XCTAssertNil(dark.summary)
        XCTAssertTrue(dark.workspaces.isEmpty)
    }
}
