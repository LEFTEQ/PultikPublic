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

    enum Failure: Error {
        case rateLimited
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
          baseRefName headRefName baseRefOid headRefOid
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
            baseSHA: pr.baseRefOid, headSHA: pr.headRefOid, additions: pr.additions, deletions: pr.deletions,
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
