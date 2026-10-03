#if DEBUG
import XCTest
@testable import Pultik

final class PanelTestDisplayTests: XCTestCase {
    func testPrefersStudioDisplayRegardlessOfScreenOrder() {
        XCTAssertEqual(PanelTestDisplay.preferredIndex(in: ["Pro Display XDR", "Studio Display", "Built-in Retina Display"]), 1)
        XCTAssertEqual(PanelTestDisplay.preferredIndex(in: ["Apple Studio Display", "Pro Display XDR"]), 0)
    }

    func testMissingStudioDisplayLeavesFocusedScreenFallback() {
        XCTAssertNil(PanelTestDisplay.preferredIndex(in: ["Built-in Retina Display", "Pro Display XDR"]))
        XCTAssertNil(PanelTestDisplay.preferredIndex(in: []))
    }
}
#endif
