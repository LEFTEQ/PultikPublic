import XCTest
@testable import Pultik

/// DESIGN.md §6, row by row, with the shared dataset's own figures.
final class PultikFormatTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testSizesAreSIWithTheUnitOnce() {
        XCTAssertEqual(PultikFormat.sizeRatio(used: 119e9, total: 147e9), "119/147 GB")
        XCTAssertEqual(PultikFormat.sizeRatio(used: 1.4e12, total: 1.7e12), "1.4/1.7 TB")
        XCTAssertEqual(PultikFormat.sizeRatio(used: 0, total: 96e9), "0/96 GB")
        XCTAssertEqual(PultikFormat.free(5.5e9), "5.5 GB free")
        XCTAssertEqual(PultikFormat.size(393e9), "393 GB")
    }

    func testCountsPercentsAndDeltas() {
        XCTAssertEqual(PultikFormat.ratio(9, of: 32), "9/32")
        XCTAssertEqual(PultikFormat.percent(0.93), "93%")
        XCTAssertEqual(PultikFormat.percent(0.98, tenths: true), "98.0%")
        XCTAssertEqual(PultikFormat.percent(0, tenths: true), "0.0%")
        XCTAssertEqual(PultikFormat.delta(1.39), "+139%")
        XCTAssertEqual(PultikFormat.count(590e6), "590 M")
        XCTAssertEqual(PultikFormat.count(8.11e9), "8.11 B")
        XCTAssertEqual(PultikFormat.count(12.3e9), "12.30 B")
        XCTAssertEqual(PultikFormat.count(332), "332")
        XCTAssertEqual(PultikFormat.quantity(83, unit: "°C"), "83 °C")
    }

    func testDurationsAndAges() {
        XCTAssertEqual(PultikFormat.duration(3), "3s")
        XCTAssertEqual(PultikFormat.duration(61), "1m 1s")
        XCTAssertEqual(PultikFormat.duration(192), "3m 12s")
        XCTAssertEqual(PultikFormat.duration(7200), "2h")
        XCTAssertEqual(PultikFormat.duration(9 * 86400), "9d")
        XCTAssertEqual(PultikFormat.age(15 * 60 + 40), "15m")
        XCTAssertEqual(PultikFormat.age(6 * 3600 + 12 * 60), "6h 12m")
        let now = Date(timeIntervalSince1970: 1_791_472_320)
        XCTAssertEqual(PultikFormat.ago(now.addingTimeInterval(-240), now: now), "4m ago")
        XCTAssertEqual(PultikFormat.ago(now.addingTimeInterval(-86400), now: now), "1d ago")
    }

    func testClockAndDates() {
        // 2026-10-08 15:12 UTC
        let now = Date(timeIntervalSince1970: 1_791_472_320)
        XCTAssertEqual(PultikFormat.clock(now, calendar: utc), "15:12")
        XCTAssertEqual(PultikFormat.asOf(now, calendar: utc), "as of 15:12")
        XCTAssertEqual(PultikFormat.date(now.addingTimeInterval(-6 * 86400), now: now, calendar: utc), "Oct 2")
        XCTAssertEqual(PultikFormat.date(now.addingTimeInterval(-366 * 86400), now: now, calendar: utc), "Oct 7, 2025")
    }
}
