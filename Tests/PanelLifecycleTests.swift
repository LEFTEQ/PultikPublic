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
}
