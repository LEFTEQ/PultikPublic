import XCTest
@testable import Pultik

final class BrightnessQueryTests: XCTestCase {
    /// The palette's one-shot brightness ask: a bare percent, with or without
    /// `%`, optionally behind a display alias. Anything else is a search.
    func testParsesLevelsAndRejectsSearches() {
        XCTAssertEqual(BrightnessQuery.parse("50"), 50)
        XCTAssertEqual(BrightnessQuery.parse("50%"), 50)
        XCTAssertEqual(BrightnessQuery.parse("Brightness 40"), 40)
        XCTAssertEqual(BrightnessQuery.parse("screen 0%"), 0)
        XCTAssertEqual(BrightnessQuery.parse("dim 30"), 30)
        XCTAssertEqual(BrightnessQuery.parse(" 100 "), 100)

        XCTAssertNil(BrightnessQuery.parse("101"))
        XCTAssertNil(BrightnessQuery.parse("-5"))
        XCTAssertNil(BrightnessQuery.parse("exampleapp 50"))
        XCTAssertNil(BrightnessQuery.parse("brightness"))
        XCTAssertNil(BrightnessQuery.parse("brightness 50 now"))
        XCTAssertNil(BrightnessQuery.parse("#50"))
    }
}
