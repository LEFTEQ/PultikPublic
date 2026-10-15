import XCTest
@testable import Pultik

/// AC 11's fixture decodes through Toolkit's generated contract
/// (`tools/fleet-contract.sh`), so a regenerated contract that drifts from
/// the fixture fails here, not in a panel-drive run.
final class FleetContractTests: XCTestCase {
    func testTheFixtureSnapshotDecodesWithItsWaitingSession() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fleet-snapshot.json")
        let snapshot = try FleetJSON.decoder().decode(FleetSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(snapshot.version, fleetSnapshotVersion)
        XCTAssertEqual(snapshot.sessions.filter { $0.state == .waiting }.map(\.name), ["fixture-waiting"])
        XCTAssertEqual(snapshot.sessions.first?.liveness, .alive)
        XCTAssertEqual(snapshot.cmux.state, .ok)
    }
}
