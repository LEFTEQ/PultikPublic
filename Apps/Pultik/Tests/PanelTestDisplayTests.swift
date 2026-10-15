#if DEBUG
import XCTest
@testable import Pultik

/// Test summons go to Toolkit's `qa` display when it is connected — a
/// preference, never a gate, and no screen name is built in.
final class PanelTestDisplayTests: XCTestCase {
    func testTheWantedScreenWinsRegardlessOfScreenOrder() {
        let screens = ["Pro Display XDR", "Studio Display", "Built-in Retina Display"]
        XCTAssertEqual(PanelTestDisplay.preferredIndex(in: screens, wanted: "Studio Display"), 1)
        XCTAssertEqual(PanelTestDisplay.preferredIndex(in: screens, wanted: "Built-in Retina Display"), 2)
    }

    func testAScreenThatIsNotConnectedOrNoneLeavesTheFocusedScreen() {
        XCTAssertNil(PanelTestDisplay.preferredIndex(in: ["Built-in Retina Display"], wanted: "Studio Display"))
        XCTAssertNil(PanelTestDisplay.preferredIndex(in: ["Studio Display", "Built-in Retina Display"], wanted: nil))
        XCTAssertNil(PanelTestDisplay.preferredIndex(in: ["Studio Display"], wanted: ""))
    }
}
#endif
