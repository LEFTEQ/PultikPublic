import XCTest
import AppKit
@testable import Pultik

final class VitrinkaDailyWorkTests: XCTestCase {
    func testPartialDailyWorkPreservesDataAndRefusalForBackoff() {
        let snapshot = VitrinkaWorkspaceSnapshot(workspace: .init(slug: "one", name: "One"), workUnavailable: true)
        let poll = VitrinkaDailyPoll(snapshots: [snapshot], failures: [.unreachable("timeout"), .rejected("HTTP 429")])
        XCTAssertEqual(poll.snapshots.first?.id, "one")
        guard case .rejected("HTTP 429") = poll.rejection else {
            return XCTFail("A usable tray must not hide a scoped rejection")
        }
        XCTAssertNil(VitrinkaDailyPoll(snapshots: [snapshot], failures: [.unreachable("timeout")]).rejection)
    }

    func testWorkspaceSelectionKeepsUnavailablePickAndUsesDefaultAfterRemoval() {
        let first = VitrinkaWorkspaceSnapshot(workspace: .init(slug: "first", name: "First"))
        let fallback = VitrinkaWorkspaceSnapshot(workspace: .init(slug: "default", name: "Default"))
        let offline = VitrinkaWorkspaceSnapshot(workspace: .init(slug: "offline", name: "Offline"), unavailable: true)
        let snapshots = [first, fallback, offline]
        let selected = VitrinkaWorkspaceSnapshot.selected(in: snapshots, preferring: "offline", defaultWorkspace: "default")
        XCTAssertEqual(selected?.id, "offline")
        XCTAssertEqual(selected?.tray.boards.count, 0)
        XCTAssertEqual(VitrinkaWorkspaceSnapshot.selected(in: snapshots, preferring: "removed", defaultWorkspace: "default")?.id, "default")
    }

    @MainActor
    func testConsumedPaletteKeysDoNotReachTheFieldEditorAgain() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        let owner = UUID()
        let router = PaletteKeyRouter.shared
        router.claim(owner) { _ in nil }
        defer { router.resign(owner) }
        XCTAssertNil(router.route(event))
        router.resign(owner)
        XCTAssertTrue(router.route(event) === event)
    }

    func testDailyWorkPrioritizesDecisionsAndDeduplicatesTasks() throws {
        let work = try JSONDecoder().decode(VitrinkaMyWork.self, from: Data("""
        {"gates":[{"task":{"id":1,"project":"demo","title":"Approve","status":"in_progress","url":"https://example.test/w/one/p/demo/t/1"}}],
         "overdue":[{"id":1,"project":"demo","title":"Approve","status":"in_progress","url":"https://example.test/w/one/p/demo/t/1"}],
         "assigned":[{"id":2,"project":"demo","title":"Build","status":"in_progress","url":"https://example.test/w/one/p/demo/t/2"},
                     {"id":3,"project":"demo","title":"Done","status":"done","url":"https://example.test/w/one/p/demo/t/3"}],
         "created":null,"mentioned":null}
        """.utf8))
        let snapshot = VitrinkaWorkspaceSnapshot(workspace: .init(slug: "one", name: "One"), work: work)
        XCTAssertEqual(snapshot.today.map(\.id), [1, 2])
        XCTAssertEqual(snapshot.today.map(\.reason), ["needs you", "assigned to you"])
        XCTAssertEqual(snapshot.today.first?.task.url.path, "/w/one/p/demo/t/1")
    }

    func testJobsSharingARunKeepSeparateGridIdentities() {
        let url = URL(string: "https://github.com/example/project/actions/runs/123")!
        let build = CIJob(org: "example", repo: "project", lane: "ci", workflow: "CI", jobName: "build", runURL: url, since: nil)
        let test = CIJob(org: "example", repo: "project", lane: "ci", workflow: "CI", jobName: "test", runURL: url, since: nil)
        XCTAssertNotEqual(build.id, test.id)
    }
}
