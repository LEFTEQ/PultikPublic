import SwiftUI
import XCTest
@testable import Pultik

final class PanelLifecycleTests: XCTestCase {
    @MainActor
    func testHiddenPanelDiscardsBothHostingReferences() {
        _ = NSApplication.shared
        var panel: StatusPanel?
        weak var container: NSViewController?
        weak var host: NSViewController?
        autoreleasepool {
            let created = StatusPanel(rootView: Text("Memory lifecycle"))
            panel = created
            container = created.contentViewController
            host = created.contentViewController?.children.first
            XCTAssertNotNil(host)
            created.discardContent()
            XCTAssertNil(created.contentViewController)
        }
        withExtendedLifetime(panel) {
            XCTAssertNil(container)
            XCTAssertNil(host, "both the container and panel must release their host")
        }
    }

    /// Stay in Pultík AC 2 (D1): a detail rested on for 1.5 s survives an
    /// Esc run out of it and a dismiss; resting on Home returns Home; hidden
    /// past 15 minutes opens on Home.
    @MainActor
    func testASummonReturnsToTheLastPlaceDwelledOn() {
        let place = PanelPlace()
        let router = place.router
        let start = Date()
        place.presented(at: start)
        router.enter(.prs, select: "pr:1", openDetail: true)
        router.push(DetailRef(kind: .run, id: "gh:o/r/run/9"))
        place.rested(on: router.place, since: start, now: start.addingTimeInterval(1.6))
        // Esc ×4 — the card, the detail, the selection, the module — each
        // faster than the dwell, then the panel closes.
        var at = start.addingTimeInterval(1.6)
        for peel in [{ router.pop() }, { router.closeDetail() }, { router.select(nil) }, { router.leave() }] {
            peel()
            place.rested(on: router.place, since: at, now: at.addingTimeInterval(0.3))
            at.addTimeInterval(0.3)
        }
        place.dismissed(at: at)
        place.presented(at: at.addingTimeInterval(35))
        XCTAssertEqual(router.module, .prs)
        XCTAssertEqual(router.selection, "pr:1")
        XCTAssertTrue(router.detailOpen)
        XCTAssertEqual(router.stack, [DetailRef(kind: .run, id: "gh:o/r/run/9")])

        router.leave()
        at.addTimeInterval(40)
        place.rested(on: router.place, since: at, now: at.addingTimeInterval(2))
        place.dismissed(at: at.addingTimeInterval(2))
        place.presented(at: at.addingTimeInterval(10))
        XCTAssertNil(router.module, "resting on Home returns Home")

        router.enter(.ci, select: "run:1", openDetail: true)
        place.rested(on: router.place, since: at, now: at.addingTimeInterval(20))
        place.dismissed(at: at.addingTimeInterval(20))
        place.presented(at: at.addingTimeInterval(20 + 16 * 60))
        XCTAssertNil(router.module, "hidden past 15 minutes opens on Home")
        XCTAssertFalse(router.detailOpen)
    }
}
