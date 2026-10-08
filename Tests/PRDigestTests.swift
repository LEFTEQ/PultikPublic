import XCTest
@testable import Pultik

final class PRDigestTests: XCTestCase {
    private struct Entry {
        let repo: String
        let info: PRInfo
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ repo: String, _ number: Int, state: CheckState = .success,
                       review: ReviewState = .approved, draft: Bool = false, daysOld: Double = 1) -> Entry {
        let pr = PullRequest(id: number, number: number, title: "#\(number)", htmlUrl: "", draft: draft,
                             head: .init(sha: "", ref: ""),
                             updatedAt: now.addingTimeInterval(-daysOld * 24 * 3600))
        return Entry(repo: repo, info: PRInfo(pr: pr, state: state, review: review))
    }

    private func digest(_ entries: [Entry]) -> PRDigest<Entry> {
        PRDigest(entries, repo: \.repo, info: \.info, now: now)
    }

    /// Needs-you PRs are rows and ready PRs are counted, per repo, in the
    /// inbox's fixed repo order; a repo with only folded PRs has no row.
    func testNeedsYouRowsAndReadyCountsKeepRepoOrder() {
        let result = digest([
            entry("o/ExampleApp", 3, state: .failure),
            entry("o/ExampleApp", 2),
            entry("o/ExampleApp", 1, review: .changesRequested),
            entry("o/eve", 9, review: .awaiting),
            entry("o/quiet", 5, draft: true),
            entry("o/vitrinka", 7),
        ])
        XCTAssertEqual(result.repos.map(\.slug), ["o/ExampleApp", "o/eve", "o/vitrinka"])
        XCTAssertEqual(result.repos[0].needsYou.map(\.info.pr.number), [3, 1])
        XCTAssertEqual(result.repos[0].ready.map(\.info.pr.number), [2])
        XCTAssertEqual(result.repos[2].needsYou.count, 0)
        XCTAssertEqual(result.needsYouCount, 3)
        XCTAssertEqual(result.readyCount, 2)
        XCTAssertEqual(result.total, 6)
        // Keyboard selection walks the drawn rows: folded lines open in place.
        XCTAssertEqual(result.visible(expanded: []).map(\.info.pr.number), [3, 1, 9])
        XCTAssertEqual(result.visible(expanded: ["o/ExampleApp", PRDigest<Entry>.foldKey]).map(\.info.pr.number),
                       [3, 1, 2, 9, 5])
    }

    /// Drafts always fold; a quiet PR untouched for 7 days folds as stale; a
    /// failing PR untouched for a month still asks for you.
    func testDraftsAndStaleFoldButNeedsYouBeatsStale() {
        let result = digest([
            entry("o/ExampleApp", 1, state: .failure, draft: true),
            entry("o/ExampleApp", 2, daysOld: 7),
            entry("o/ExampleApp", 3, daysOld: 6.9),
            entry("o/ExampleApp", 4, state: .failure, daysOld: 30),
        ])
        XCTAssertEqual(result.drafts.map(\.info.pr.number), [1])
        XCTAssertEqual(result.stale.map(\.info.pr.number), [2])
        XCTAssertEqual(result.repos.first?.ready.map(\.info.pr.number), [3])
        XCTAssertEqual(result.repos.first?.needsYou.map(\.info.pr.number), [4])
    }
}
