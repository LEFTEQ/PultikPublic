import Foundation

/// One pull request read natively (copilot shell WP5, D7): what the estate's
/// inbox read does not carry. The conversation — description, reviews,
/// review threads, every check — is one GraphQL read that moves without a
/// push. The changed files and their patches are one REST compare addressed
/// by `base...head` SHA, so they never change for a key: a reopen at the same
/// head is served from the query repository without a request (AC 9).
/// Foundation-only: the contract harness decodes it.
enum GitHubPRDetail {
    /// GitHub holds more than these and says so (`threadsTruncated`,
    /// `checksTruncated`).
    static let threadLimit = 50
    static let checkLimit = 100
    /// Conversations per batched query (the warm set, D9).
    static let batchSize = 10

    /// The workbench's timeline reads the newest this many events
    /// (`timelineTruncated`), the pending review this many comments.
    static let timelineLimit = 100
    static let pendingCommentLimit = 100

    enum Failure: Error {
        case rateLimited
        /// The credential lacks a scope one field needs (`read:org` for
        /// teams): GitHub answers no data at all.
        case insufficientScopes
    }

    // MARK: - Conversation (GraphQL)

    /// Everything the detail reads of one PR — the single read and the
    /// batched one select exactly the same, so a warm conversation is the
    /// one ↵ would have read.
    private static var fields: String {
        """
        fragment PRFields on PullRequest {
          number title url body state isDraft createdAt updatedAt mergedAt
          author { login }
          baseRefName headRefName baseRefOid headRefOid baseRef { target { oid } }
          additions deletions changedFiles mergeable reviewDecision
          reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
          latestOpinionatedReviews(first: 20) { nodes { author { login } state submittedAt } }
          reviewThreads(first: \(threadLimit)) {
            totalCount
            nodes { id path line originalLine isResolved isOutdated
              comments(first: 20) { nodes { author { login } body createdAt url diffHunk } } }
          }
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: \(checkLimit)) {
            totalCount
            nodes {
              __typename
              ... on CheckRun { id name status conclusion detailsUrl startedAt completedAt
                checkSuite { workflowRun { databaseId workflow { name } } } }
              ... on StatusContext { id context state targetUrl createdAt }
            }
          } } } } }
        }
        """
    }

    static func body(repo: String, number: Int) throws -> Data {
        try batchBody([ChangeRequestRef(repo: repo, number: number)])
    }

    /// Up to `batchSize` PRs in one query, one aliased repository each
    /// (`r0`, `r1`, …). Owners, names and numbers travel as variables, never
    /// spliced into the query text.
    static func batchBody(_ refs: [ChangeRequestRef]) throws -> Data {
        var declarations: [String] = []
        var selections: [String] = []
        var variables: [String: Any] = [:]
        for (index, ref) in refs.enumerated() {
            let parts = ref.repo.split(separator: "/", maxSplits: 1).map(String.init)
            declarations.append("$o\(index): String!, $n\(index): String!, $p\(index): Int!")
            selections.append("r\(index): repository(owner: $o\(index), name: $n\(index)) { pullRequest(number: $p\(index)) { ...PRFields } }")
            variables["o\(index)"] = parts.first ?? ref.repo
            variables["n\(index)"] = parts.count > 1 ? parts[1] : ""
            variables["p\(index)"] = ref.number
        }
        let query = "query(\(declarations.joined(separator: ", "))) {\n\(selections.joined(separator: "\n"))\n}\n" + fields
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// Quota exhaustion arrives inside an HTTP 200 and throws `rateLimited`;
    /// a missing PR or repository is a GraphQL error, never an empty PR.
    static func decodeConversation(_ data: Data, ref: ChangeRequestRef, decoder: JSONDecoder) throws -> ChangeRequest {
        let response = try decoder.decode(BatchResponse.self, from: data)
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw Failure.rateLimited }
        guard let node = response.data?["r0"]??.pullRequest else {
            throw GitHubError.graphQL(errors.first?.message ?? "pull request not found")
        }
        return changeRequest(node, ref: ref)
    }

    /// A batched answer, by the refs asked in order. A PR GitHub could not
    /// read (deleted, a repository gone) is absent, never an empty PR; quota
    /// exhaustion throws for the whole batch.
    static func decodeBatch(_ data: Data, refs: [ChangeRequestRef],
                            decoder: JSONDecoder) throws -> [ChangeRequestRef: ChangeRequest] {
        let response = try decoder.decode(BatchResponse.self, from: data)
        if (response.errors ?? []).contains(where: { $0.type == "RATE_LIMITED" }) { throw Failure.rateLimited }
        var answer: [ChangeRequestRef: ChangeRequest] = [:]
        for (index, ref) in refs.enumerated() {
            if let node = response.data?["r\(index)"]??.pullRequest { answer[ref] = changeRequest(node, ref: ref) }
        }
        return answer
    }

    private static func changeRequest(_ pr: PRNode, ref: ChangeRequestRef) -> ChangeRequest {
        let threads = pr.reviewThreads.nodes.compactMap { $0 }.map { node in
            let comments = node.comments.nodes.compactMap { $0 }
            return ChangeRequest.ReviewThread(
                id: node.id, path: node.path, line: node.line ?? node.originalLine,
                isResolved: node.isResolved, isOutdated: node.isOutdated, hunk: comments.first?.diffHunk ?? "",
                comments: comments.map { ChangeRequest.Comment(author: $0.author?.login ?? "ghost", body: $0.body,
                                                               createdAt: $0.createdAt, url: $0.url) })
        }
        let rollup = pr.commits.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.contexts
        let checks = (rollup?.nodes.compactMap { $0 } ?? []).compactMap(check)
            .sorted { ($0.outcome, $0.title) < ($1.outcome, $1.title) }
        let state: ChangeRequest.State = switch pr.state {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
        let mergeable: ChangeRequest.Mergeability = switch pr.mergeable {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: .unknown
        }
        return ChangeRequest(
            ref: ChangeRequestRef(repo: ref.repo, number: pr.number), title: pr.title, url: pr.url, body: pr.body,
            state: state, isDraft: pr.isDraft, author: pr.author?.login, createdAt: pr.createdAt,
            updatedAt: pr.updatedAt, mergedAt: pr.mergedAt, baseRef: pr.baseRefName, headRef: pr.headRefName,
            baseSHA: pr.baseRefOid, headSHA: pr.headRefOid, baseTipSHA: pr.baseRef?.target?.oid,
            additions: pr.additions, deletions: pr.deletions,
            changedFiles: pr.changedFiles, mergeable: mergeable, decision: pr.reviewDecision.flatMap(verdict),
            reviews: pr.latestOpinionatedReviews.nodes.compactMap { $0 }.map {
                ChangeRequest.Review(author: $0.author?.login ?? "ghost", verdict: verdict($0.state) ?? .commented,
                                     submittedAt: $0.submittedAt)
            },
            requested: pr.reviewRequests.nodes.compactMap { $0?.requestedReviewer?.name },
            threads: threads, checks: checks,
            threadsTruncated: pr.reviewThreads.totalCount > threads.count,
            checksTruncated: (rollup?.totalCount ?? 0) > checks.count)
    }

    /// GitHub's review states and branch-rule decisions, one vocabulary.
    private static func verdict(_ state: String) -> ChangeRequest.Verdict? {
        switch state {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        case "COMMENTED": .commented
        case "DISMISSED": .dismissed
        case "PENDING": .pending
        default: nil
        }
    }

    /// A check run's status and conclusion, or a commit status's state, as
    /// one outcome. Cancelled, timed-out and action-required runs fail.
    private static func check(_ node: ContextNode) -> ChangeRequest.Check? {
        if node.typename == "StatusContext" {
            guard let context = node.context else { return nil }
            let outcome: ChangeRequest.Check.Outcome = switch node.state {
            case "SUCCESS": .passed
            case "FAILURE", "ERROR": .failed
            default: .running
            }
            return ChangeRequest.Check(nodeID: node.id, name: context, workflow: nil, outcome: outcome,
                                       url: node.targetUrl, startedAt: node.createdAt, completedAt: nil, runID: nil)
        }
        guard let name = node.name else { return nil }
        let outcome: ChangeRequest.Check.Outcome
        if node.status != "COMPLETED" {
            outcome = .running
        } else {
            switch node.conclusion {
            case "SUCCESS": outcome = .passed
            case "SKIPPED", "NEUTRAL", "STALE": outcome = .skipped
            default: outcome = .failed
            }
        }
        let run = node.checkSuite?.workflowRun
        return ChangeRequest.Check(nodeID: node.id, name: name, workflow: run?.workflow?.name, outcome: outcome,
                                   url: node.detailsUrl, startedAt: node.startedAt, completedAt: node.completedAt,
                                   runID: run?.databaseId)
    }

    // MARK: - Activity (GraphQL, PR workbench D4, D8)

    /// The timeline's kinds: what `TimelineEvent.Kind` draws, nothing else.
    private static let timelineKinds = """
        ISSUE_COMMENT, PULL_REQUEST_REVIEW, PULL_REQUEST_COMMIT, HEAD_REF_FORCE_PUSHED_EVENT, MERGED_EVENT,
        CLOSED_EVENT, REOPENED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT, REVIEW_REQUESTED_EVENT,
        LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT, RENAMED_TITLE_EVENT, BASE_REF_CHANGED_EVENT
        """

    /// Everything the workbench reads beside the conversation, in one query.
    /// A pending review comment carries no diff side of its own; its thread
    /// does, so the newest threads' sides travel with their first comment's id.
    private static var activityQuery: String {
        """
        query($owner: String!, $name: String!, $number: Int!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
            mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed autoMergeAllowed deleteBranchOnMerge
            viewerDefaultMergeMethod
            pullRequest(number: $number) {
              id state updatedAt headRefOid isCrossRepository mergeStateStatus
              viewerCanUpdate viewerCanMergeAsAdmin viewerCanUpdateBranch viewerCanDeleteHeadRef
              viewerCanEnableAutoMerge viewerCanDisableAutoMerge
              autoMergeRequest { mergeMethod }
              headRef { id }
              commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              labels(first: 50) { nodes { id name color description } }
              assignees(first: 20) { nodes { id login name } }
              milestone { id number title dueOn }
              suggestedReviewers { reviewer { login } }
              reviewRequests(first: 20) { nodes { requestedReviewer { __typename
                ... on User { id login name } ... on Bot { id login } ... on Team { id name slug } } } }
              reviews(states: PENDING, first: 1) { nodes { id viewerDidAuthor
                comments(first: \(pendingCommentLimit)) { nodes { id path line startLine originalLine originalStartLine body } } } }
              reviewThreads(last: 100) { nodes { diffSide startDiffSide comments(first: 1) { nodes { id } } } }
              timelineItems(last: \(timelineLimit), itemTypes: [\(timelineKinds)]) {
                pageInfo { hasPreviousPage }
                nodes {
                  __typename
                  ... on IssueComment { id author { login } createdAt url body }
                  ... on PullRequestReview { id author { login } createdAt submittedAt url state body comments { totalCount } }
                  ... on PullRequestCommit { id url commit { oid messageHeadline committedDate author { name user { login } } } }
                  ... on HeadRefForcePushedEvent { id actor { login } createdAt beforeCommit { oid } afterCommit { oid } }
                  ... on MergedEvent { id actor { login } createdAt url commit { oid } }
                  ... on ClosedEvent { id actor { login } createdAt url }
                  ... on ReopenedEvent { id actor { login } createdAt }
                  ... on ReadyForReviewEvent { id actor { login } createdAt url }
                  ... on ConvertToDraftEvent { id actor { login } createdAt url }
                  ... on ReviewRequestedEvent { id actor { login } createdAt
                    requestedReviewer { ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Team { name } } }
                  ... on LabeledEvent { id actor { login } createdAt label { name } }
                  ... on UnlabeledEvent { id actor { login } createdAt label { name } }
                  ... on AssignedEvent { id actor { login } createdAt
                    assignee { ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Organization { login } } }
                  ... on RenamedTitleEvent { id actor { login } createdAt previousTitle currentTitle }
                  ... on BaseRefChangedEvent { id actor { login } createdAt previousRefName currentRefName }
                }
              }
            }
          }
        }
        """
    }

    /// Owner, name and number travel as variables, never spliced.
    static func activityBody(_ ref: ChangeRequestRef) throws -> Data {
        let parts = ref.repo.split(separator: "/", maxSplits: 1).map(String.init)
        let variables: [String: Any] = ["owner": parts.first ?? ref.repo, "name": parts.count > 1 ? parts[1] : "",
                                        "number": ref.number]
        return try JSONSerialization.data(withJSONObject: ["query": activityQuery, "variables": variables])
    }

    /// Quota exhaustion throws `rateLimited`; a missing PR is a GraphQL
    /// error, never an empty activity.
    static func decodeActivity(_ data: Data, decoder: JSONDecoder) throws -> ChangeRequestActivity {
        let response = try decoder.decode(ActivityResponse.self, from: data)
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw Failure.rateLimited }
        guard let answer = response.data, let repository = answer.repository, let pr = repository.pullRequest else {
            throw GitHubError.graphQL(errors.first?.message ?? "pull request not found")
        }
        return activity(pr, repository: repository, viewer: answer.viewer.login)
    }

    private static func activity(_ pr: ActivityPRNode, repository: ActivityRepository,
                                 viewer: String) -> ChangeRequestActivity {
        let allowed: [(Bool, MergeMethod)] = [(repository.mergeCommitAllowed, .merge),
                                              (repository.squashMergeAllowed, .squash),
                                              (repository.rebaseMergeAllowed, .rebase)]
        let methods = allowed.filter(\.0).map(\.1)
        let state = mergeState(pr.mergeStateStatus)
        let rollup = pr.commits.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state
        let merge = MergeOptions(
            methods: methods,
            preferred: mergeMethod(repository.viewerDefaultMergeMethod).flatMap { methods.contains($0) ? $0 : nil },
            autoMergeAllowed: repository.autoMergeAllowed,
            autoMerge: pr.autoMergeRequest.flatMap { mergeMethod($0.mergeMethod) },
            deleteBranchOnMerge: repository.deleteBranchOnMerge, state: state,
            headRefID: pr.isCrossRepository ? nil : pr.headRef?.id,
            // A merged or closed request reads UNKNOWN for good: nothing left to settle.
            settled: pr.state != "OPEN" || (state != .unknown && rollup != "PENDING" && rollup != "EXPECTED"))
        var people: [Person] = []
        var teams: [Team] = []
        for reviewer in pr.reviewRequests.nodes.compactMap({ $0?.requestedReviewer }) {
            switch (reviewer.typename, reviewer.id, reviewer.login, reviewer.name, reviewer.slug) {
            case ("User", let id?, let login?, let name, _): people.append(Person(id: id, login: login, name: name))
            case ("Bot", let id?, let login?, _, _): people.append(Person(id: id, login: login, name: nil, isBot: true))
            case ("Team", let id?, _, let name?, let slug?): teams.append(Team(id: id, name: name, slug: slug))
            default: continue // a mannequin: nothing a verb can ask again
            }
        }
        return ChangeRequestActivity(
            nodeID: pr.id, updatedAt: pr.updatedAt, headSHA: pr.headRefOid, viewer: viewer,
            timeline: pr.timelineItems.nodes.compactMap { $0.flatMap(event) },
            timelineTruncated: pr.timelineItems.pageInfo.hasPreviousPage,
            labels: pr.labels.nodes.compactMap { $0.map(label) },
            assignees: pr.assignees.nodes.compactMap { $0.map(person) },
            milestone: pr.milestone.map(milestone),
            requestedReviewers: people, requestedTeams: teams, merge: merge,
            rights: ViewerRights(canUpdate: pr.viewerCanUpdate, canMergeAsAdmin: pr.viewerCanMergeAsAdmin,
                                 canUpdateBranch: pr.viewerCanUpdateBranch, canDeleteHeadRef: pr.viewerCanDeleteHeadRef,
                                 canEnableAutoMerge: pr.viewerCanEnableAutoMerge,
                                 canDisableAutoMerge: pr.viewerCanDisableAutoMerge),
            pendingReview: pendingReview(pr),
            suggestedReviewers: pr.suggestedReviewers.compactMap { $0?.reviewer?.login })
    }

    /// The viewer's own pending review; each comment's side comes from its
    /// thread, right (the head) when the thread is past the newest hundred.
    private static func pendingReview(_ pr: ActivityPRNode) -> PendingReview? {
        guard let review = pr.reviews.nodes.compactMap({ $0 }).first(where: \.viewerDidAuthor) else { return nil }
        var sides: [String: (side: String, start: String?)] = [:]
        for thread in pr.reviewThreads.nodes.compactMap({ $0 }) {
            if let first = thread.comments.nodes.first??.id { sides[first] = (thread.diffSide, thread.startDiffSide) }
        }
        let comments = review.comments.nodes.compactMap { $0 }.compactMap { node -> DraftReviewComment? in
            // A file-level comment has no line to draw it on.
            guard let line = node.line ?? node.originalLine else { return nil }
            let startLine = node.startLine ?? node.originalStartLine
            let side = sides[node.id]
            return DraftReviewComment(id: node.id, path: node.path, line: line, side: diffSide(side?.side) ?? .right,
                                      startLine: startLine,
                                      startSide: startLine == nil ? nil : diffSide(side?.start) ?? diffSide(side?.side) ?? .right,
                                      body: node.body)
        }
        return PendingReview(id: review.id, comments: comments)
    }

    /// One timeline node as the workbench draws it; a kind it does not
    /// draw, or a node missing what its kind needs, is skipped.
    private static func event(_ node: TimelineNode) -> TimelineEvent? {
        guard let id = node.id else { return nil }
        var actor = node.actor?.login
        var at = node.createdAt
        let kind: TimelineEvent.Kind
        switch node.typename {
        case "IssueComment":
            actor = node.author?.login
            kind = .comment(body: node.body ?? "")
        case "PullRequestReview":
            // The viewer's pending review is `pendingReview`, not history.
            guard let state = node.state, state != "PENDING", let verdict = verdict(state) else { return nil }
            actor = node.author?.login
            at = node.submittedAt ?? node.createdAt
            kind = .review(verdict: verdict, body: node.body ?? "", comments: node.comments?.totalCount ?? 0)
        case "PullRequestCommit":
            guard let commit = node.commit else { return nil }
            actor = commit.author?.user?.login ?? commit.author?.name
            at = commit.committedDate
            kind = .commit(sha: commit.oid, headline: commit.messageHeadline ?? "")
        case "HeadRefForcePushedEvent": kind = .forcePush(before: node.beforeCommit?.oid, after: node.afterCommit?.oid)
        case "MergedEvent": kind = .merged(sha: node.commit?.oid)
        case "ClosedEvent": kind = .closed
        case "ReopenedEvent": kind = .reopened
        case "ReadyForReviewEvent": kind = .readyForReview
        case "ConvertToDraftEvent": kind = .convertedToDraft
        case "ReviewRequestedEvent":
            guard let name = node.requestedReviewer?.name else { return nil }
            kind = .reviewRequested(name)
        case "LabeledEvent":
            guard let name = node.label?.name else { return nil }
            kind = .labeled(name)
        case "UnlabeledEvent":
            guard let name = node.label?.name else { return nil }
            kind = .unlabeled(name)
        case "AssignedEvent":
            guard let login = node.assignee?.login else { return nil }
            kind = .assigned(login)
        case "RenamedTitleEvent":
            guard let from = node.previousTitle, let to = node.currentTitle else { return nil }
            kind = .renamed(from: from, to: to)
        case "BaseRefChangedEvent":
            guard let from = node.previousRefName, let to = node.currentRefName else { return nil }
            kind = .baseChanged(from: from, to: to)
        default: return nil
        }
        guard let at else { return nil }
        return TimelineEvent(id: id, actor: actor, at: at, url: node.url, kind: kind)
    }

    private static func mergeState(_ status: String) -> MergeState {
        switch status {
        case "CLEAN": .clean
        case "BEHIND": .behind
        case "BLOCKED": .blocked
        case "DIRTY": .dirty
        case "DRAFT": .draft
        case "HAS_HOOKS": .hasHooks
        case "UNSTABLE": .unstable
        default: .unknown
        }
    }

    private static func mergeMethod(_ method: String?) -> MergeMethod? {
        switch method {
        case "MERGE": .merge
        case "SQUASH": .squash
        case "REBASE": .rebase
        default: nil
        }
    }

    private static func diffSide(_ side: String?) -> DraftReviewComment.Side? {
        switch side {
        case "LEFT": .left
        case "RIGHT": .right
        default: nil
        }
    }

    private static func label(_ node: LabelNode) -> ChangeRequestLabel {
        ChangeRequestLabel(id: node.id, name: node.name, color: node.color, description: node.description)
    }

    private static func person(_ node: PersonNode) -> Person {
        Person(id: node.id, login: node.login, name: node.name)
    }

    private static func milestone(_ node: MilestoneNode) -> Milestone {
        Milestone(id: node.id, number: node.number, title: node.title, dueOn: node.dueOn)
    }

    // MARK: - Metadata choices (GraphQL, PR workbench D4)

    /// The pickers' choices, read when one opens. Teams need `read:org` and an
    /// organisation owner; `teams: false` is the read without them.
    static func choicesBody(repo: String, teams: Bool) throws -> Data {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        let owner = teams
            ? "owner { ... on Organization { teams(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { id name slug } } } }"
            : ""
        let query = """
            query($owner: String!, $name: String!) {
              repository(owner: $owner, name: $name) {
                labels(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { id name color description } }
                milestones(first: 50, states: OPEN, orderBy: {field: DUE_DATE, direction: ASC}) { nodes { id number title dueOn } }
                assignableUsers(first: 100) { nodes { id login name } }
                \(owner)
              }
            }
            """
        let variables: [String: Any] = ["owner": parts.first ?? repo, "name": parts.count > 1 ? parts[1] : ""]
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// A user-owned repository, or teams GitHub withheld beside a readable
    /// repository, read as no teams. A missing scope throws
    /// `insufficientScopes`, for the read without teams.
    static func decodeChoices(_ data: Data, decoder: JSONDecoder) throws -> MetadataChoices {
        let response = try decoder.decode(ChoicesResponse.self, from: data)
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw Failure.rateLimited }
        guard let repository = response.data?.repository else {
            if errors.contains(where: { $0.type == "INSUFFICIENT_SCOPES" }) { throw Failure.insufficientScopes }
            throw GitHubError.graphQL(errors.first?.message ?? "repository not found")
        }
        return MetadataChoices(
            labels: repository.labels.nodes.compactMap { $0.map(label) },
            milestones: repository.milestones.nodes.compactMap { $0.map(milestone) },
            people: repository.assignableUsers.nodes.compactMap { $0.map(person) },
            teams: repository.owner?.teams?.nodes.compactMap { $0.map { Team(id: $0.id, name: $0.name, slug: $0.slug) } } ?? [])
    }

    // MARK: - Files (REST compare)

    /// `?per_page=1`: only the first page carries the files, and one commit
    /// is all this read needs of the comparison's commit list.
    static func comparePath(repo: String, base: String, head: String) -> String {
        "/repos/\(repo)/compare/\(base)...\(head)?per_page=1"
    }

    /// `expected` is the conversation's `changedFiles`: GitHub's compare
    /// returns at most 300, so a larger PR reads truncated.
    static func decodeFiles(_ data: Data, expected: Int, decoder: JSONDecoder) throws -> ChangeSet {
        let compare = try decoder.decode(Compare.self, from: data)
        let files = (compare.files ?? []).map { file in
            (path: file.filename, previousPath: file.previousFilename,
             status: ChangedFile.Status(rawValue: file.status) ?? .modified,
             additions: file.additions, deletions: file.deletions, patch: file.patch)
        }
        return ChangeSet.bounded(files, truncated: expected > files.count)
    }

    // MARK: - Wire

    /// The single and the batched read alike: one aliased repository per PR.
    private struct BatchResponse: Decodable {
        let data: [String: RepositoryNode?]?
        let errors: [GraphQLFailure]?
    }

    private struct GraphQLFailure: Decodable {
        let type: String?
        let message: String
    }

    private struct RepositoryNode: Decodable {
        let pullRequest: PRNode?
    }

    private struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node?]
    }

    private struct CountedConnection<Node: Decodable>: Decodable {
        let totalCount: Int
        let nodes: [Node?]
    }

    /// A ref's commit (`baseRef { target { oid } }`).
    private struct RefNode: Decodable {
        struct Target: Decodable {
            let oid: String
        }

        let target: Target?
    }

    private struct Actor: Decodable {
        let login: String
    }

    private struct PRNode: Decodable {
        let number: Int
        let title: String
        let url: String
        let body: String
        let state: String
        let isDraft: Bool
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let author: Actor?
        let baseRefName: String
        let headRefName: String
        let baseRefOid: String
        let headRefOid: String
        /// The base branch now; nil once it is deleted.
        let baseRef: RefNode?
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let mergeable: String
        let reviewDecision: String?
        let reviewRequests: Connection<RequestNode>
        /// Opinionated, like the estate's: a later comment-only review must
        /// not erase a reviewer's standing approval or change request.
        let latestOpinionatedReviews: Connection<ReviewNode>
        let reviewThreads: CountedConnection<ThreadNode>
        let commits: Connection<CommitNode>
    }

    private struct RequestNode: Decodable {
        let requestedReviewer: Reviewer?

        /// A user by login, a team by name; a mannequin or bot reads absent.
        struct Reviewer: Decodable {
            let login: String?
            let teamName: String?
            var name: String? { login ?? teamName }

            enum CodingKeys: String, CodingKey { case login, teamName = "name" }
        }
    }

    private struct ReviewNode: Decodable {
        let author: Actor?
        let state: String
        let submittedAt: Date?
    }

    private struct ThreadNode: Decodable {
        let id: String
        let path: String
        let line: Int?
        let originalLine: Int?
        let isResolved: Bool
        let isOutdated: Bool
        let comments: Connection<CommentNode>
    }

    private struct CommentNode: Decodable {
        let author: Actor?
        let body: String
        let createdAt: Date
        let url: String
        let diffHunk: String?
    }

    private struct CommitNode: Decodable {
        let commit: Commit
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let contexts: CountedConnection<ContextNode> }
    }

    private struct ContextNode: Decodable {
        let typename: String
        let id: String?
        // CheckRun
        let name: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: String?
        let startedAt: Date?
        let completedAt: Date?
        let checkSuite: Suite?
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: String?
        let createdAt: Date?

        struct Suite: Decodable {
            let workflowRun: Run?
        }

        struct Run: Decodable {
            let databaseId: Int?
            let workflow: Workflow?
        }

        struct Workflow: Decodable {
            let name: String
        }

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, name, status, conclusion, detailsUrl, startedAt, completedAt, checkSuite
            case context, state, targetUrl, createdAt
        }
    }

    private struct ActivityResponse: Decodable {
        let data: ActivityData?
        let errors: [GraphQLFailure]?
    }

    private struct ActivityData: Decodable {
        let viewer: Actor
        let repository: ActivityRepository?
    }

    private struct ActivityRepository: Decodable {
        let mergeCommitAllowed: Bool
        let squashMergeAllowed: Bool
        let rebaseMergeAllowed: Bool
        let autoMergeAllowed: Bool
        let deleteBranchOnMerge: Bool
        let viewerDefaultMergeMethod: String?
        let pullRequest: ActivityPRNode?
    }

    private struct ActivityPRNode: Decodable {
        let id: String
        let updatedAt: Date
        let headRefOid: String
        let state: String
        let isCrossRepository: Bool
        let mergeStateStatus: String
        let viewerCanUpdate: Bool
        let viewerCanMergeAsAdmin: Bool
        let viewerCanUpdateBranch: Bool
        let viewerCanDeleteHeadRef: Bool
        let viewerCanEnableAutoMerge: Bool
        let viewerCanDisableAutoMerge: Bool
        let autoMergeRequest: AutoMerge?
        let headRef: NodeID?
        let commits: Connection<StateCommit>
        let labels: Connection<LabelNode>
        let assignees: Connection<PersonNode>
        let milestone: MilestoneNode?
        let suggestedReviewers: [Suggested?]
        let reviewRequests: Connection<ActivityRequest>
        let reviews: Connection<PendingNode>
        let reviewThreads: Connection<SideNode>
        let timelineItems: TimelineConnection

        struct AutoMerge: Decodable { let mergeMethod: String }
        struct Suggested: Decodable { let reviewer: Actor? }
    }

    private struct NodeID: Decodable {
        let id: String
    }

    private struct StateCommit: Decodable {
        let commit: Commit
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let state: String }
    }

    private struct LabelNode: Decodable {
        let id: String
        let name: String
        let color: String
        let description: String?
    }

    private struct PersonNode: Decodable {
        let id: String
        let login: String
        let name: String?
    }

    private struct MilestoneNode: Decodable {
        let id: String
        let number: Int
        let title: String
        let dueOn: Date?
    }

    /// A user or bot by login and display name, a team by name and slug.
    private struct ActivityRequest: Decodable {
        let requestedReviewer: Reviewer?

        struct Reviewer: Decodable {
            let typename: String
            let id: String?
            let login: String?
            let name: String?
            let slug: String?

            enum CodingKeys: String, CodingKey { case typename = "__typename", id, login, name, slug }
        }
    }

    private struct PendingNode: Decodable {
        let id: String
        let viewerDidAuthor: Bool
        let comments: Connection<DraftNode>
    }

    private struct DraftNode: Decodable {
        let id: String
        let path: String
        let line: Int?
        let startLine: Int?
        let originalLine: Int?
        let originalStartLine: Int?
        let body: String
    }

    /// A thread's sides, keyed by its first comment.
    private struct SideNode: Decodable {
        let diffSide: String
        let startDiffSide: String?
        let comments: Connection<NodeID>
    }

    private struct TimelineConnection: Decodable {
        let pageInfo: PageInfo
        let nodes: [TimelineNode?]

        struct PageInfo: Decodable { let hasPreviousPage: Bool }
    }

    /// Every timeline kind in one shape: each fills what its fragment selects.
    private struct TimelineNode: Decodable {
        let typename: String
        let id: String?
        let author: Actor?
        let actor: Actor?
        let createdAt: Date?
        let submittedAt: Date?
        let url: String?
        let body: String?
        let state: String?
        let comments: Count?
        let commit: Commit?
        let beforeCommit: Commit?
        let afterCommit: Commit?
        let requestedReviewer: RequestNode.Reviewer?
        let label: Named?
        let assignee: Login?
        let previousTitle: String?
        let currentTitle: String?
        let previousRefName: String?
        let currentRefName: String?

        struct Count: Decodable { let totalCount: Int }
        struct Named: Decodable { let name: String }
        struct Login: Decodable { let login: String? }

        struct Commit: Decodable {
            let oid: String
            let messageHeadline: String?
            let committedDate: Date?
            let author: Author?

            struct Author: Decodable {
                let name: String?
                let user: Login?
            }
        }

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, author, actor, createdAt, submittedAt, url, body, state, comments, commit, beforeCommit, afterCommit
            case requestedReviewer, label, assignee, previousTitle, currentTitle, previousRefName, currentRefName
        }
    }

    private struct ChoicesResponse: Decodable {
        let data: ChoicesData?
        let errors: [GraphQLFailure]?
    }

    private struct ChoicesData: Decodable {
        let repository: ChoicesRepository?
    }

    private struct ChoicesRepository: Decodable {
        let labels: Connection<LabelNode>
        let milestones: Connection<MilestoneNode>
        let assignableUsers: Connection<PersonNode>
        /// A user owner answers `{}`; the read without teams selects none.
        let owner: Owner?

        struct Owner: Decodable { let teams: Connection<TeamNode>? }
        struct TeamNode: Decodable {
            let id: String
            let name: String
            let slug: String
        }
    }

    private struct Compare: Decodable {
        let files: [CompareFile]?
    }

    private struct CompareFile: Decodable {
        let filename: String
        let previousFilename: String?
        let status: String
        let additions: Int
        let deletions: Int
        let patch: String?
    }
}
