import XCTest
@testable import Pultik

/// WP5: the PR detail's two reads — the GraphQL conversation and the files
/// compare — and the diff lines the AppKit surface draws.
final class GitHubPRDetailTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let ref = ChangeRequestRef(repo: "o/eve", number: 412)

    func testConversationLeadsWithFailingChecksAndKeepsThreadsReviewsAndRequests() throws {
        let body = """
            {"data": {"r0": {"pullRequest": {
              "number": 412, "title": "Provider pool cooldown", "url": "https://github.com/o/eve/pull/412",
              "body": "Fixes the cooldown.", "state": "OPEN", "isDraft": false,
              "createdAt": "2026-10-02T09:00:00Z", "updatedAt": "2026-10-10T14:00:00Z", "mergedAt": null,
              "author": {"login": "lukas"}, "baseRefName": "main", "headRefName": "feat/pool",
              "baseRefOid": "base1", "headRefOid": "head1", "additions": 120, "deletions": 30, "changedFiles": 4,
              "mergeable": "MERGEABLE", "reviewDecision": "CHANGES_REQUESTED",
              "reviewRequests": {"nodes": [{"requestedReviewer": {"login": "eve-bot"}},
                                           {"requestedReviewer": {"name": "core"}}, {"requestedReviewer": null}]},
              "latestOpinionatedReviews": {"nodes": [{"author": {"login": "ana"}, "state": "CHANGES_REQUESTED",
                                                      "submittedAt": "2026-10-09T10:00:00Z"}]},
              "reviewThreads": {"totalCount": 3, "nodes": [
                {"id": "T1", "path": "src/pool.ts", "line": null, "originalLine": 88, "isResolved": false,
                 "isOutdated": true, "comments": {"nodes": [
                   {"author": null, "body": "Why reset here?", "createdAt": "2026-10-09T10:01:00Z",
                    "url": "https://github.com/o/eve/pull/412#r1", "diffHunk": "@@ -80,3 +80,4 @@\\n a\\n+b"}]}},
                {"id": "T2", "path": "README.md", "line": 3, "originalLine": 3, "isResolved": true,
                 "isOutdated": false, "comments": {"nodes": []}}]},
              "commits": {"nodes": [{"commit": {"statusCheckRollup": {"contexts": {"totalCount": 4, "nodes": [
                {"__typename": "CheckRun", "id": "CR1", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS",
                 "detailsUrl": "https://x/1", "startedAt": "2026-10-10T13:00:00Z", "completedAt": "2026-10-10T13:00:41Z",
                 "checkSuite": {"workflowRun": {"databaseId": 8812, "workflow": {"name": "CI"}}}},
                {"__typename": "CheckRun", "id": "CR2", "name": "test", "status": "COMPLETED", "conclusion": "TIMED_OUT",
                 "detailsUrl": "https://x/2", "startedAt": null, "completedAt": null, "checkSuite": null},
                {"__typename": "CheckRun", "id": "CR3", "name": "build", "status": "IN_PROGRESS", "conclusion": null,
                 "detailsUrl": null, "startedAt": null, "completedAt": null, "checkSuite": null},
                {"__typename": "CheckRun", "id": "CR4", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS",
                 "detailsUrl": null, "startedAt": null, "completedAt": null, "checkSuite": null},
                {"__typename": "StatusContext", "id": "SC1", "context": "deploy/preview", "state": "SUCCESS",
                 "targetUrl": "https://preview", "createdAt": "2026-10-10T13:05:00Z"}]}}}}]}
            }}}}
            """
        let pr = try GitHubPRDetail.decodeConversation(Data(body.utf8), ref: ref, decoder: decoder)
        XCTAssertEqual(pr.checks.map(\.name), ["test", "build", "lint", "build", "deploy/preview"],
                       "failed, then running, then passed")
        XCTAssertEqual(pr.checks.map(\.outcome), [.failed, .running, .passed, .passed, .passed],
                       "a timed-out run fails")
        XCTAssertEqual(Set(pr.checks.map(\.id)).count, 5, "the same job run twice is two rows")
        XCTAssertEqual(pr.checks[2].runID, 8812)
        XCTAssertEqual(pr.checks[2].duration, 41)
        XCTAssertFalse(pr.checksTruncated)
        XCTAssertEqual(pr.threads.first?.line, 88, "an outdated thread falls back to its original line")
        XCTAssertEqual(pr.threads.first?.comments.first?.author, "ghost")
        XCTAssertTrue(pr.threadsTruncated, "GitHub holds three threads, the read returned two")
        XCTAssertEqual(pr.requested, ["eve-bot", "core"])
        XCTAssertEqual(pr.reviews.first?.verdict, .changesRequested)
        XCTAssertEqual(pr.reviewVerdict, .changesRequested)
        XCTAssertEqual(pr.ref.key, "gh:o/eve#412")
        XCTAssertEqual([pr.baseSHA, pr.headSHA], ["base1", "head1"])
    }

    func testQuotaExhaustionAndAMissingPullRequestNeverDecodeAsAnEmptyPR() {
        let limited = #"{"data": null, "errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#
        XCTAssertThrowsError(try GitHubPRDetail.decodeConversation(Data(limited.utf8), ref: ref, decoder: decoder)) { error in
            guard case GitHubPRDetail.Failure.rateLimited = error else { return XCTFail("\(error)") }
        }
        let missing = #"{"data": {"r0": {"pullRequest": null}}, "errors": [{"type": "NOT_FOUND", "message": "gone"}]}"#
        XCTAssertThrowsError(try GitHubPRDetail.decodeConversation(Data(missing.utf8), ref: ref, decoder: decoder)) { error in
            guard case GitHubError.graphQL("gone") = error else { return XCTFail("\(error)") }
        }
    }

    func testFilesKeepTheirHeadersPastThePatchBudgetAndReadTruncatedPastGitHubsCap() throws {
        let long = (0 ..< ChangeSet.patchLineLimit + 5).map { "+line \($0)" }.joined(separator: "\\n")
        let huge = String(repeating: "x", count: ChangeSet.patchByteBudget)
        let body = """
            {"files": [
              {"filename": "a.swift", "previous_filename": "old.swift", "status": "renamed", "additions": 605,
               "deletions": 0, "patch": "@@ -0,0 +1,605 @@\\n\(long)"},
              {"filename": "b.bin", "status": "added", "additions": 0, "deletions": 0},
              {"filename": "c.txt", "status": "modified", "additions": 1, "deletions": 0, "patch": "+\(huge)"}]}
            """
        let files = try GitHubPRDetail.decodeFiles(Data(body.utf8), expected: 301, decoder: decoder)
        XCTAssertTrue(files.truncated)
        let first = files.files[0]
        XCTAssertEqual(first.previousPath, "old.swift")
        XCTAssertTrue(first.trimmed)
        XCTAssertEqual(first.patch?.split(separator: "\n").count, ChangeSet.patchLineLimit)
        XCTAssertNil(files.files[1].patch)
        XCTAssertFalse(files.files[1].trimmed, "a binary file is not a budget cut")
        XCTAssertNil(files.files[2].patch, "past the PR's byte budget the file keeps its header only")
        XCTAssertTrue(files.files[2].trimmed)
        XCTAssertEqual(GitHubPRDetail.comparePath(repo: "o/eve", base: "b", head: "h"),
                       "/repos/o/eve/compare/b...h?per_page=1")
    }

    func testDiffLinesCarryBothGutterNumbersAcrossHunks() {
        let patch = "@@ -10,3 +10,3 @@ func pool()\n context\n-old\n+new\n \n\\ No newline at end of file\n@@ -40,1 +40,2 @@\n x\n+y\n"
        let lines = DiffLine.parse(patch)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .removed, .added, .context, .note, .hunk, .context, .added])
        XCTAssertEqual(lines[1].old, 10)
        XCTAssertEqual(lines[2].old, 11)
        XCTAssertNil(lines[2].new)
        XCTAssertEqual(lines[3].new, 11)
        XCTAssertEqual([lines[4].old, lines[4].new], [12, 12], "a blank context line is a line")
        XCTAssertEqual(lines[8].new, 41)
    }
}
