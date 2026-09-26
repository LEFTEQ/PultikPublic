import XCTest
@testable import Pultik

/// One devbox over several guests (spec 2026-09-25): discovery, the merge,
/// the per-box breakdown and the row tags.
final class DevboxBoxesTests: XCTestCase {
    private static let gib = DevboxGlance.gib
    private let boxB = DevboxEndpoint(name: "b", sshAlias: "devops-b", host: "192.0.2.11", port: 2223)

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
        {"name":"c","host":"x","ssh":"devops-c","state":"drain","reachable":false,"error":"timeout","fix":"ssh x"}
        """))
        XCTAssertEqual(found.map(\.name), ["a", "c"])
        let many = (1 ... 10).map { #"{"name":"x\#($0)","ssh":"devops","state":"active"}"# }
        XCTAssertEqual(candidates(many.joined(separator: ","))?.count, DevboxDiscovery.boxLimit)
        let endpoint = DevboxDiscovery.endpoint(
            for: found[0], sshConfig: "host devops\nuser devbox\nhostname 192.0.2.11\nport 2222\nidentityfile ~/.ssh/id\n")
        XCTAssertEqual(endpoint, .fallback)
        XCTAssertEqual(endpoint?.destination, "devbox@192.0.2.11")
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
        XCTAssertEqual(DevboxGlance(summary: own, workspaces: estate.workspaces).boxes, [])
        XCTAssertEqual(estate.workspaces.map(\.box), [.fallback])
        XCTAssertEqual(estate.workspaces.map(\.id), ["a/demo"])
    }

    func testSeveralBoxesAddUpToOneDevboxAndTheWorstBoxSetsThePressure() throws {
        let a = summary(running: 3, parked: 10, cpus: 48, cpu: 50, totalGB: 84, availableGB: 24, disk: (300, 500))
        // b sits 2G below its floor; a's headroom must not hide it.
        let b = summary(running: 2, parked: 5, cpus: 16, cpu: 10, totalGB: 48, availableGB: 6, disk: (100, 200))
        let estate = DevboxEstate(boxes: [.fallback, boxB],
                                  snapshots: [snapshot(boxB, b, rows: ["web"]), snapshot(.fallback, a, rows: ["api"])])
        let merged = try XCTUnwrap(estate.summary)
        XCTAssertEqual(merged.running, 5)
        XCTAssertEqual(merged.parked, 15)
        XCTAssertEqual(merged.floorGB, 16)
        XCTAssertEqual(merged.diskUsedBytes, 400 * Self.gib)
        XCTAssertEqual(merged.diskTotalBytes, 700 * Self.gib)
        XCTAssertEqual(merged.pressure, .critical)
        let glance = DevboxGlance(summary: merged, workspaces: estate.workspaces)
        XCTAssertEqual(glance.cpuPercent, 40) // core-weighted: (50·48 + 10·16) / 64
        XCTAssertEqual(glance.cores, 64)
        XCTAssertEqual(glance.memoryUsedBytes, 102 * Self.gib)
        XCTAssertEqual(glance.memoryTotalBytes, 132 * Self.gib)
        XCTAssertEqual(glance.headroomBytes, 14 * Self.gib)
        XCTAssertEqual(glance.boxes.map(\.label), ["a 16G free", "b \u{2212}2.0G free"])
        XCTAssertEqual(estate.workspaces.map(\.id), ["a/api", "b/web"])
    }

    func testASilentBoxIsMarkedAndNeverBlanksTheOthers() throws {
        let b = summary(running: 2, parked: 5, cpus: 16, cpu: 10, totalGB: 48, availableGB: 39)
        let estate = DevboxEstate(boxes: [.fallback, boxB], snapshots: [snapshot(boxB, b, rows: ["web"])])
        let merged = try XCTUnwrap(estate.summary)
        XCTAssertEqual(merged.running, 2)
        let shares = DevboxGlance(summary: merged, workspaces: estate.workspaces).boxes
        XCTAssertEqual(shares.map(\.label), ["a silent", "b 31G free"])
        XCTAssertEqual(shares.map(\.isSilent), [true, false])
        XCTAssertEqual(estate.workspaces.map { $0.box?.name }, ["b"])

        let dark = DevboxEstate(boxes: [.fallback, boxB], snapshots: [])
        XCTAssertNil(dark.summary)
        XCTAssertTrue(dark.workspaces.isEmpty)
    }
}
