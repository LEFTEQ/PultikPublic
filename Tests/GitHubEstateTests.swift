import XCTest
@testable import Pultik

/// Fixture shaped like a live estate answer (2026-10-05): one repository that
/// resolves and one that GitHub reports as NOT_FOUND in the same HTTP 200.
final class GitHubEstateTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func testOneReadMapsInboxDeploysAndDeltaAndAMissingRepoFailsAlone() throws {
        let body = """
            {"data": {"r0": {
              "open": {"nodes": [
                {"databaseId": 11, "number": 7, "title": "Red", "url": "https://github.com/o/a/pull/7",
                 "isDraft": false, "updatedAt": "2026-10-05T10:00:00Z", "headRefName": "work/red", "headRefOid": "abc",
                 "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE"}}}]},
                 "latestOpinionatedReviews": {"nodes": [{"state": "APPROVED"}, {"state": "CHANGES_REQUESTED"}]}},
                {"databaseId": 12, "number": 8, "title": "Quiet", "url": "https://github.com/o/a/pull/8",
                 "isDraft": true, "updatedAt": "2026-10-05T09:00:00Z", "headRefName": "work/quiet", "headRefOid": "def",
                 "commits": {"nodes": [{"commit": {"statusCheckRollup": null}}]},
                 "latestOpinionatedReviews": {"nodes": []}}]},
              "recent": {"nodes": [
                {"number": 6, "title": "Shipped", "url": "https://github.com/o/a/pull/6", "state": "MERGED",
                 "isDraft": false, "mergedAt": "2026-10-05T08:00:00Z", "updatedAt": "2026-10-05T08:00:00Z",
                 "headRefName": "work/shipped"}]},
              "deployments": {"nodes": [
                {"databaseId": 3, "environment": "prod", "createdAt": "2026-10-05T07:00:00Z", "commitOid": "1234567890",
                 "ref": null, "latestStatus": {"state": "IN_PROGRESS", "environmentUrl": null, "logUrl": "https://log"}},
                {"databaseId": 2, "environment": "prod", "createdAt": "2026-10-04T07:00:00Z", "commitOid": "0",
                 "ref": {"name": "main"}, "latestStatus": {"state": "SUCCESS", "environmentUrl": "https://old", "logUrl": null}}]}
            }, "r1": null},
             "errors": [{"type": "NOT_FOUND", "path": ["r1"], "message": "Could not resolve to a Repository"}]}
            """
        let answer = try GitHubEstate.decode(Data(body.utf8), repos: ["o/a", "o/gone"], decoder: decoder)
        let repo = try XCTUnwrap(answer.repos["o/a"])
        XCTAssertNil(repo.error)
        XCTAssertEqual(repo.prs.map(\.pr.number), [7, 8])
        XCTAssertEqual(repo.prs[0].state, .failure)
        XCTAssertEqual(repo.prs[0].review, .changesRequested, "changes requested dominates an approval")
        XCTAssertEqual(repo.prs[1].state, .none)
        XCTAssertTrue(repo.prs[1].isDraft)
        XCTAssertEqual(repo.deploys.map(\.id), [3], "latest deployment per environment")
        XCTAssertEqual(repo.deploys.first?.state, "in_progress")
        XCTAssertEqual(repo.deploys.first?.deployment.ref, "1234567")
        XCTAssertEqual(repo.deploys.first?.url, "https://log")
        XCTAssertEqual(repo.recent.first?.outcome, .merged)
        XCTAssertEqual(repo.recent.first?.branch, "work/shipped")
        XCTAssertEqual(answer.repos["o/gone"]?.error, "GitHub GraphQL: Could not resolve to a Repository")
        XCTAssertFalse(answer.rateLimited)
    }

    func testQuotaExhaustionInsideA200IsReportedNotDecodedAsEmpty() throws {
        let body = #"{"data": null, "errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#
        let answer = try GitHubEstate.decode(Data(body.utf8), repos: ["o/a"], decoder: decoder)
        XCTAssertTrue(answer.rateLimited)
        XCTAssertTrue(answer.repos.isEmpty)
    }
}
