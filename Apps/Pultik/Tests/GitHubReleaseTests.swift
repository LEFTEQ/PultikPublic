import XCTest
@testable import Pultik

/// WP7: a deployment's release line — what the environment runs (its newest
/// successful deployment), a newer one failing, and the branch's commits
/// waiting to ship, cut at the live commit.
final class GitHubReleaseTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func testLiveIsTheNewestSuccessAndWaitingStopsAtTheLiveCommit() throws {
        let source = GitHubRelease.Source(repo: "example-org/ExampleApp", environment: "production")
        let deployments = """
            {"data": {"repository": {"defaultBranchRef": {"name": "main"}, "deployments": {"nodes": [
              {"databaseId": 3, "commitOid": "ccc333", "createdAt": "2026-10-11T08:00:00Z", "ref": {"name": "main"},
               "creator": {"login": "ci"}, "latestStatus": {"state": "FAILURE", "createdAt": "2026-10-11T08:05:00Z",
               "environmentUrl": null, "logUrl": "https://x/log/3"}},
              {"databaseId": 2, "commitOid": "bbb222", "createdAt": "2026-10-09T08:00:00Z", "ref": {"name": "main"},
               "creator": {"login": "ci"}, "latestStatus": {"state": "SUCCESS", "createdAt": "2026-10-09T08:09:00Z",
               "environmentUrl": "https://exampleapp.app", "logUrl": null}},
              {"databaseId": 1, "commitOid": "aaa111", "createdAt": "2026-10-08T08:00:00Z", "ref": {"name": "main"},
               "creator": null, "latestStatus": {"state": "INACTIVE", "createdAt": null,
               "environmentUrl": null, "logUrl": null}}]}}}}
            """
        let read = try GitHubRelease.decodeDeployments(Data(deployments.utf8), source: source, decoder: decoder)
        XCTAssertEqual(read.branch, "main")
        XCTAssertEqual(read.live?.sha, "bbb222")
        XCTAssertEqual(read.latest?.sha, "ccc333")
        XCTAssertEqual(read.latest?.isFailed, true)

        let branch = """
            {"data": {"repository": {"ref": {"compare": {"aheadBy": 0, "behindBy": 2},
              "target": {"oid": "ddd444", "history": {"nodes": [
                {"oid": "ddd444", "messageHeadline": "fix(admin): erased case", "committedDate": "2026-10-11T01:00:00Z",
                 "author": {"name": "the operator", "user": {"login": "lukas"}}},
                {"oid": "ccc333", "messageHeadline": "feat: pool", "committedDate": "2026-10-10T01:00:00Z",
                 "author": {"name": "Bot", "user": null}},
                {"oid": "bbb222", "messageHeadline": "live", "committedDate": "2026-10-09T01:00:00Z", "author": null},
                {"oid": "aaa111", "messageHeadline": "older", "committedDate": "2026-10-08T01:00:00Z", "author": null}]}}}}}}
            """
        let line = try GitHubRelease.decodeLine(Data(branch.utf8), source: source, deployments: read, decoder: decoder)
        XCTAssertEqual(line.waiting, 2)
        XCTAssertEqual(line.commits.map(\.sha), ["ddd444", "ccc333"])
        XCTAssertEqual(line.commits.map(\.author), ["lukas", "Bot"])
        XCTAssertEqual(line.branchHead, "ddd444")

        // A rate limit inside the 200 defers, never decodes as an empty line.
        let limited = #"{"data": null, "errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#
        XCTAssertThrowsError(try GitHubRelease.decodeDeployments(Data(limited.utf8), source: source, decoder: decoder))
    }
}
