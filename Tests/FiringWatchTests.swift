import XCTest
@testable import Pultik

final class FiringWatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let both: Set<FiringAlert.Source> = [.prometheus, .loki]

    private func alert(_ name: String, _ severity: String = "critical", container: String = "api",
                       source: FiringAlert.Source = .prometheus) -> FiringAlert
    {
        FiringAlert(name: name, state: "firing", severity: severity, summary: "\(name) summary",
                    description: nil,
                    labels: ["alertname": name, "severity": severity, "container": container,
                             "app": "exampleapp", "environment": "production"],
                    activeAt: t0, source: source)
    }

    /// A watch past its silent first answer (nothing firing at launch).
    private func primed() -> FiringWatch {
        var watch = FiringWatch()
        _ = watch.update([], answered: both, now: t0)
        return watch
    }

    func testNewCriticalNotifiesPerInstanceAndABurstCollapses() {
        var watch = primed()
        let notices = watch.update([alert("ApiDown"), alert("ApiDown", container: "worker")],
                                   answered: both, now: t0)
        XCTAssertEqual(notices, Array(repeating: .init(title: "🔴 ApiDown",
                                                        body: "exampleapp · production — ApiDown summary"), count: 2))

        let burst = watch.update(["A", "B", "C", "D"].map { alert($0) }, answered: both, now: t0)
        XCTAssertEqual(burst.map(\.title), ["🔴 4 critical alerts firing", "✅ ApiDown resolved", "✅ ApiDown resolved"])
        XCTAssertEqual(burst.first?.body, "A, B, C, D")
    }

    func testWarningNeverNotifies() {
        var watch = primed()
        XCTAssertEqual(watch.update([alert("DiskSpace", "warning")], answered: both, now: t0), [])
        XCTAssertEqual(watch.update([], answered: both, now: t0), [])
    }

    func testCriticalsFiringAtLaunchStaySilent() {
        var watch = FiringWatch()
        XCTAssertEqual(watch.update([alert("ApiDown")], answered: both, now: t0), [])
        XCTAssertEqual(watch.update([alert("ApiDown")], answered: both, now: t0), [])
        // Never announced, so its end is not announced either.
        XCTAssertEqual(watch.update([], answered: both, now: t0), [])
    }

    func testResolveNotifiesOnceAndASilentLokiResolvesNothing() {
        var watch = primed()
        _ = watch.update([alert("ApiDown"), alert("LogErrors", source: .loki)], answered: both, now: t0)
        // Loki did not answer: its rule is still firing as far as we know.
        XCTAssertEqual(watch.update([alert("ApiDown")], answered: [.prometheus], now: t0), [])

        let resolved = watch.update([alert("LogErrors", source: .loki)], answered: both, now: t0)
        XCTAssertEqual(resolved, [.init(title: "✅ ApiDown resolved", body: "exampleapp · production — ApiDown summary")])
        XCTAssertEqual(watch.update([alert("LogErrors", source: .loki)], answered: both, now: t0), [])
    }

    func testFlapWithinThirtyMinutesWaitsTheWindowOut() {
        var watch = primed()
        _ = watch.update([alert("ApiDown")], answered: both, now: t0)
        _ = watch.update([], answered: both, now: t0)
        let back = t0.addingTimeInterval(10 * 60)
        XCTAssertEqual(watch.update([alert("ApiDown")], answered: both, now: back), [])
        XCTAssertEqual(watch.update([alert("ApiDown")], answered: both, now: t0.addingTimeInterval(29 * 60)), [])
        // Still firing once the window has passed: a sustained re-fire speaks.
        XCTAssertEqual(watch.update([alert("ApiDown")], answered: both, now: t0.addingTimeInterval(31 * 60)).map(\.title),
                       ["🔴 ApiDown"])
    }
}
