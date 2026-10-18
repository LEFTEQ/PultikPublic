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
              "baseRefOid": "base1", "headRefOid": "head1", "baseRef": {"target": {"oid": "tip1"}},
              "additions": 120, "deletions": 30, "changedFiles": 4,
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
        XCTAssertEqual(pr.baseTipSHA, "tip1", "the merge preview's ours: the base branch now")
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

    /// PR workbench AC 10: the timeline (comments, reviews, pushes and every
    /// other kind it draws), merge options, rights, metadata and the
    /// viewer's pending review, from a fixture shaped like GitHub's answer.
    func testActivityReadsTheTimelineMergeOptionsMetadataAndThePendingReview() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/github-pr-activity.json")
        let activity = try GitHubPRDetail.decodeActivity(try Data(contentsOf: url), decoder: decoder)
        XCTAssertEqual(activity.nodeID, "PR_kwDOfixture")
        XCTAssertEqual(activity.viewer, "example-org")
        XCTAssertEqual(activity.headSHA, "1d9ca5081659ab7e78075ba4f10f5f62aa75663a")

        let at = { (iso: String) in try XCTUnwrap(ISO8601DateFormatter().date(from: iso)) }
        XCTAssertEqual(activity.timeline.map(\.kind), [
            .commit(sha: "471d747", headline: "feat(pool): cooldown"),
            .commit(sha: "aa11", headline: "wip"),
            .comment(body: "eve review: approve"),
            .review(verdict: .changesRequested, body: "Two things.", comments: 2),
            .forcePush(before: "aa11", after: nil),
            .convertedToDraft, .readyForReview,
            .reviewRequested("developers"), .reviewRequested("ana"),
            .labeled("bug"), .unlabeled("wip"), .assigned("example-org"),
            .renamed(from: "Pool cooldown", to: "Provider pool cooldown"),
            .baseChanged(from: "release", to: "main"),
            .closed, .reopened, .merged(sha: "f00d"),
        ], "the pending review, an undrawn kind and a null node are not history")
        XCTAssertEqual(activity.timeline.map(\.actor).prefix(4), ["example-org", "CI Bot", "eve-bot-example", "ana"],
                       "a commit names its GitHub user, else its git author")
        XCTAssertEqual(activity.timeline[3].at, try at("2026-10-15T01:04:12Z"), "a review is dated by its submission")
        XCTAssertEqual(activity.timeline[0].url, "https://github.com/o/eve/pull/412/commits/471d747")
        XCTAssertNil(activity.timeline[13].actor, "a base change GitHub made itself has no actor")
        XCTAssertTrue(activity.timelineTruncated, "GitHub holds older events than the read returned")

        XCTAssertEqual(activity.merge.methods, [.squash, .rebase])
        XCTAssertNil(activity.merge.preferred, "the viewer's last method is no longer allowed")
        XCTAssertEqual(activity.merge.autoMerge, .squash)
        XCTAssertTrue(activity.merge.autoMergeAllowed)
        XCTAssertFalse(activity.merge.deleteBranchOnMerge)
        XCTAssertEqual(activity.merge.state, .blocked)
        XCTAssertNil(activity.merge.headRefID, "a fork's branch is not ours to delete")
        XCTAssertFalse(activity.merge.settled, "a check is still running")
        XCTAssertEqual(activity.rights, ViewerRights(canUpdate: true, canMergeAsAdmin: false, canUpdateBranch: true,
                                                     canDeleteHeadRef: false, canEnableAutoMerge: false,
                                                     canDisableAutoMerge: true))

        XCTAssertEqual(activity.labels.map(\.name), ["eve-ignore", "bug"])
        XCTAssertNil(activity.labels[1].description)
        XCTAssertEqual(activity.assignees, [Person(id: "MDQ6VXNlcjEyMTU3ODU3", login: "example-org", name: "Example User")])
        XCTAssertEqual(activity.milestone, Milestone(id: "MI_1", number: 2, title: "1.8 (pre-release)",
                                                     dueOn: try at("2026-10-31T00:00:00Z")))
        XCTAssertEqual(activity.requestedReviewers, [
            Person(id: "U_ana", login: "ana", name: nil),
            Person(id: "BOT_copilot", login: "copilot-pull-request-reviewer", name: nil, isBot: true),
        ])
        XCTAssertEqual(activity.requestedTeams, [Team(id: "T_dev", name: "developers", slug: "developers")])
        XCTAssertEqual(activity.suggestedReviewers, ["livihenderson"])

        XCTAssertEqual(activity.pendingReview, PendingReview(id: "PRR_pending", comments: [
            DraftReviewComment(id: "PRRC_1", path: "src/pool.ts", line: 42, side: .left, startLine: nil, startSide: nil,
                               body: "Why reset here?"),
            DraftReviewComment(id: "PRRC_2", path: "src/pool.ts", line: 12, side: .right, startLine: 9, startSide: .left,
                               body: "This range moved."),
            DraftReviewComment(id: "PRRC_3", path: "README.md", line: 7, side: .right, startLine: nil, startSide: nil,
                               body: "Outdated."),
        ]), "sides come from each comment's thread; a file-level comment has no line to draw on")
    }

    func testAMergedRequestIsSettledAndAMissingOneNeverDecodesAsAnEmptyActivity() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/github-pr-activity.json")
        let merged = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: #""state": "OPEN""#, with: #""state": "MERGED""#)
            .replacingOccurrences(of: #""mergeStateStatus": "BLOCKED""#, with: #""mergeStateStatus": "UNKNOWN""#)
        let activity = try GitHubPRDetail.decodeActivity(Data(merged.utf8), decoder: decoder)
        XCTAssertEqual(activity.merge.state, .unknown)
        XCTAssertTrue(activity.merge.settled, "a merged request's UNKNOWN never settles; it has nothing left to settle")

        let missing = #"{"data": {"viewer": {"login": "example-org"}, "repository": {"mergeCommitAllowed": true, "squashMergeAllowed": false, "rebaseMergeAllowed": false, "autoMergeAllowed": false, "deleteBranchOnMerge": true, "viewerDefaultMergeMethod": "MERGE", "pullRequest": null}}, "errors": [{"type": "NOT_FOUND", "message": "Could not resolve to a PullRequest with the number of 9."}]}"#
        XCTAssertThrowsError(try GitHubPRDetail.decodeActivity(Data(missing.utf8), decoder: decoder)) { error in
            guard case GitHubError.graphQL("Could not resolve to a PullRequest with the number of 9.") = error else {
                return XCTFail("\(error)")
            }
        }
        let limited = #"{"data": null, "errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}"#
        XCTAssertThrowsError(try GitHubPRDetail.decodeActivity(Data(limited.utf8), decoder: decoder)) { error in
            guard case GitHubPRDetail.Failure.rateLimited = error else { return XCTFail("\(error)") }
        }
    }

    func testChoicesReadNoTeamsFromAUserOwnerAndAMissingScopeAskForTheReadWithout() throws {
        let org = """
            {"data": {"repository": {
              "labels": {"nodes": [{"id": "LA_1", "name": "bug", "color": "d73a4a", "description": null}]},
              "milestones": {"nodes": [{"id": "MI_1", "number": 1, "title": "CI/CD", "dueOn": null}]},
              "assignableUsers": {"nodes": [{"id": "U_1", "login": "example-org", "name": "Example User"}]},
              "owner": {"teams": {"nodes": [{"id": "T_1", "name": "developers", "slug": "developers"}]}}}}}
            """
        let choices = try GitHubPRDetail.decodeChoices(Data(org.utf8), decoder: decoder)
        XCTAssertEqual(choices.labels, [ChangeRequestLabel(id: "LA_1", name: "bug", color: "d73a4a", description: nil)])
        XCTAssertEqual(choices.milestones.map(\.number), [1])
        XCTAssertEqual(choices.people, [Person(id: "U_1", login: "example-org", name: "Example User")])
        XCTAssertEqual(choices.teams, [Team(id: "T_1", name: "developers", slug: "developers")])

        let user = org.replacingOccurrences(
            of: #""owner": {"teams": {"nodes": [{"id": "T_1", "name": "developers", "slug": "developers"}]}}"#,
            with: #""owner": {}"#)
        XCTAssertEqual(try GitHubPRDetail.decodeChoices(Data(user.utf8), decoder: decoder).teams, [])
        let withheld = org.replacingOccurrences(of: #"{"teams": {"nodes": [{"id": "T_1", "name": "developers", "slug": "developers"}]}}"#,
                                                with: #"{"teams": null}"#)
        XCTAssertEqual(try GitHubPRDetail.decodeChoices(Data(withheld.utf8), decoder: decoder).teams, [],
                       "teams GitHub withheld beside a readable repository are no teams, never a failure")

        let scoped = #"{"errors": [{"type": "INSUFFICIENT_SCOPES", "message": "Your token has not been granted the required scopes to execute this query. The 'teams' field requires one of the following scopes: ['read:org']"}]}"#
        XCTAssertThrowsError(try GitHubPRDetail.decodeChoices(Data(scoped.utf8), decoder: decoder)) { error in
            guard case GitHubPRDetail.Failure.insufficientScopes = error else { return XCTFail("\(error)") }
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try GitHubPRDetail.choicesBody(repo: "example-org/Exports", teams: false)) as? [String: Any])
        XCTAssertFalse((body["query"] as? String ?? "").contains("teams"), "the read without teams selects none")
        XCTAssertEqual(body["variables"] as? [String: String], ["owner": "example-org", "name": "Exports"])
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
