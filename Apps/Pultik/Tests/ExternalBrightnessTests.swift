import XCTest
@testable import Pultik

final class ExternalBrightnessTests: XCTestCase {
    /// The LG runs the offset darker than every level, floored at 10 % and
    /// never brighter than the Apple panels (spec 2026-10-01).
    func testOffsetIsFlooredAndNeverBrightens() {
        XCTAssertEqual(BrightnessStore.externalPercent(70, offset: 20), 50)
        XCTAssertEqual(BrightnessStore.externalPercent(100, offset: 20), 80)
        XCTAssertEqual(BrightnessStore.externalPercent(20, offset: 20), 10)
        XCTAssertEqual(BrightnessStore.externalPercent(25, offset: 20), 10)
        XCTAssertEqual(BrightnessStore.externalPercent(10, offset: 20), 10)
        XCTAssertEqual(BrightnessStore.externalPercent(5, offset: 20), 5)
        XCTAssertEqual(BrightnessStore.externalPercent(0, offset: 20), 0)
        XCTAssertEqual(BrightnessStore.externalPercent(70, offset: 0), 70)
    }
}
