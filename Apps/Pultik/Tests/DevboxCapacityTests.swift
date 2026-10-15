import XCTest
@testable import Pultik

final class DevboxCapacityTests: XCTestCase {
    func testPortRangeUsesActualLeaseAndLegacyFallback() {
        var workspace = DevboxWorkspace(
            name: "demo", project: nil, branch: nil, portBase: 21300,
            portCount: 3, created: nil, apps: [], stats: [], memoryBytes: 0,
            cpuPercent: 0, declaredSources: []
        )
        XCTAssertEqual(workspace.portWindowLabel, "21300–21302")
        workspace.portCount = 1
        XCTAssertEqual(workspace.portWindowLabel, "21300")
        workspace.portCount = nil
        XCTAssertEqual(workspace.portWindowLabel, "21300–21319")
        workspace.portCount = 0
        XCTAssertNil(workspace.portWindowLabel)
        workspace.portCount = Int.max
        XCTAssertNil(workspace.portWindowLabel)
    }

    private func summary(_ json: String) throws -> DevboxOverviewSummary {
        let capacity = try JSONDecoder().decode(DevboxOverviewCapacity.self, from: Data(json.utf8))
        return DevboxOverviewSummary(
            identitySlots: capacity.identitySlots, targetHot: capacity.targetHot,
            hotCeiling: capacity.hotCeiling ?? capacity.targetHot,
            claimed: capacity.claimed, running: capacity.running, identities: capacity.identities,
            parked: capacity.parked ?? 0, floorGB: capacity.floorGB ?? 0,
            pressureSome: capacity.pressureSome ?? 0, pressureFull: capacity.pressureFull ?? 0,
            cpus: 48, load1: 1, memoryTotalBytes: 86 * 1_073_741_824,
            memoryAvailableBytes: 24 * 1_073_741_824, swapTotalBytes: 0, swapFreeBytes: 0
        )
    }

    func testDynamicCapacitySeparatesSavedWorkspacesFromPortsAndAdmission() throws {
        let value = try summary("""
        {"identitySlots":0,"targetHot":22,"hotCeiling":22,"claimed":11,"running":11,
         "parked":5,"floorGB":8,"identities":{"used":45,"capacity":0,"saved":45,
         "runtimeLeases":11,"portsUsed":27,"portCapacity":600}}
        """)
        XCTAssertEqual(value.shortLabel, "11 running · 5 parked · 24G free / 8G floor")
        XCTAssertTrue(value.helpLabel.contains("45 saved workspaces · 11 workspaces with ports"))
        XCTAssertTrue(value.helpLabel.contains("27 of 600 ports allocated · admission by RAM"))
        XCTAssertFalse(value.helpLabel.contains("identities claimed"))
        XCTAssertFalse(value.helpLabel.contains("ceiling"))
    }

    func testOlderGuestKeepsItsFiniteCapacityMeaning() throws {
        for identities in ["", ",\"identities\":{\"used\":30,\"capacity\":30}"] {
            let value = try summary("""
            {"identitySlots":30,"targetHot":22,"claimed":30,"running":11\(identities)}
            """)
            XCTAssertTrue(value.shortLabel.hasPrefix("11 hot of 22"))
            XCTAssertTrue(value.helpLabel.contains("30 of 30 identities claimed"))
            XCTAssertFalse(value.helpLabel.contains("saved workspaces"))
        }
    }

    func testZeroCapacityWithoutNewCountersDoesNotInventCountsOrDenominators() throws {
        let value = try summary("""
        {"identitySlots":0,"targetHot":0,"claimed":11,"running":11}
        """)
        XCTAssertTrue(value.shortLabel.hasPrefix("11 running"))
        XCTAssertTrue(value.helpLabel.contains("admission by RAM"))
        XCTAssertFalse(value.helpLabel.contains("of 0"))
        XCTAssertFalse(value.helpLabel.contains("saved workspaces"))
        XCTAssertFalse(value.helpLabel.contains("workspaces with ports"))
    }
}
