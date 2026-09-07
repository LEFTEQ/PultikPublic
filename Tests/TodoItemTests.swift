import XCTest
@testable import Pultik

/// The wire contract the panel reads: a `todo` task as `/api/v1/tasks` and
/// `/api/v1/me/ripe` emit it, decoded into the row every surface paints.
final class TodoItemTests: XCTestCase {
    func testDecodesTaskWithMomentFieldsAndRipeness() throws {
        let json = """
        {"id":120,"project":"example-studio","title":"fix-the-portal-claim-bug","status":"todo",
         "dueAt":"2026-08-31T11:20:00Z","priority":"high","milestoneId":null,
         "createdAt":"2026-09-05T10:18:32.656814Z","type":"todo",
         "fields":{"branch":"main","commit":"3b8d3fd","lead":"1h","every":"1w",
                   "trigger":"when the PR merges","context":"# Context"}}
        """
        let todo = try JSONDecoder().decode(TodoItem.self, from: Data(json.utf8))
        XCTAssertEqual(todo.id, 120)
        XCTAssertEqual(todo.name, "fix-the-portal-claim-bug")
        XCTAssertEqual(todo.lead, 3600)
        XCTAssertEqual(todo.every, "1w")
        XCTAssertTrue(todo.hasContext)
        XCTAssertTrue(todo.isOpen)
        XCTAssertNotNil(todo.createdAt, "fractional-second timestamps must decode")
        let due = try XCTUnwrap(todo.dueAt)
        XCTAssertFalse(todo.isRipe(due.addingTimeInterval(-2 * 3600)), "outside a 1h lead")
        XCTAssertTrue(todo.isRipe(due.addingTimeInterval(-30 * 60)), "inside a 1h lead")
        XCTAssertTrue(todo.isOverdue(due.addingTimeInterval(1)))
        XCTAssertEqual(todo.occurrenceKey, "120@\(Int(due.timeIntervalSince1970))")
        XCTAssertEqual(todo.url.absoluteString,
                       VitrinkaClient.shared.base.appending(path: "p/example-studio").absoluteString + "?task=120")
    }

    @MainActor
    func testReminderMergeKeepsServerVerdictOnScheduledRows() {
        let future = Date.now.addingTimeInterval(7 * 86400)
        let scheduled = [TodoItem(id: 1, project: "p", title: "later", dueAt: future)]
        let ripe = [
            TodoItem(id: 1, project: "p", title: "later", dueAt: future, reason: "milestone", milestoneName: "cut"),
            TodoItem(id: 2, project: "p", title: "gate", reason: "milestone", milestoneName: "cut"),
            TodoItem(id: 3, project: "p", title: "soon", dueAt: .now, reason: "due"),
        ]
        let merged = TodoStore.mergeReminderCandidates(scheduled: scheduled, ripe: ripe)
        XCTAssertEqual(merged.map(\.id), [1, 2, 3],
                       "scheduled order first; every ripe row the open list lacks — milestone-only AND a due one past the page cap — is appended, none duplicated")
        XCTAssertTrue(merged[0].isRipe(), "a future dueAt with a reached milestone is ripe NOW")
        XCTAssertEqual(merged[0].milestoneName, "cut")
        XCTAssertTrue(merged[2].isRipe(), "a ripe row absent from the open list still surfaces")
    }

    func testMilestoneRipenessComesFromTheServer() throws {
        let json = #"{"id":7,"project":"vitrinka","title":"ship-it","milestoneId":3,"fields":{}}"#
        var todo = try JSONDecoder().decode(TodoItem.self, from: Data(json.utf8))
        XCTAssertFalse(todo.isRipe(), "no clock, no server verdict")
        todo.reason = "milestone"
        todo.milestoneName = "v2 cut"
        XCTAssertTrue(todo.isRipe())
        XCTAssertFalse(todo.isOverdue())
        XCTAssertEqual(todo.when, "milestone: v2 cut")
        XCTAssertEqual(todo.occurrenceKey, "7@milestone")
    }
}
