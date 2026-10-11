import Foundation

/// One pull request read natively (copilot shell WP5, D7): what the estate's
/// inbox read does not carry. The conversation — description, reviews,
/// review threads, every check — is one GraphQL read that moves without a
/// push. The changed files and their patches are one REST compare addressed
/// by `base...head` SHA, so they never change for a key: a reopen at the same
/// head is served from the query repository without a request (AC 9).
/// Foundation-only: the contract harness decodes it.
enum GitHubPRDetail {
    /// Everything about a PR that can change without a push.
    struct Conversation: Codable, Sendable, Equatable {
        let number: Int
        let title: String
        let url: String
        let body: String
        /// OPEN · CLOSED · MERGED
        let state: String
        let isDraft: Bool
        let author: String?
        let createdAt: Date
        let updatedAt: Date
        let mergedAt: Date?
        let baseRef: String
        let headRef: String
        /// The files key: the compare runs `baseSHA...headSHA`, the merge
        /// base against the head, exactly GitHub's "Files changed" — and the
        /// pair names one diff for good.
        let baseSHA: String
        let headSHA: String
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        /// MERGEABLE · CONFLICTING · UNKNOWN
        let mergeable: String
        /// APPROVED · CHANGES_REQUESTED · REVIEW_REQUIRED, nil without rules.
        let reviewDecision: String?
        let reviews: [Review]
        /// Reviewers still asked, users by login and teams by name.
        let requested: [String]
        let threads: [Thread]
        let checks: [Check]
        /// GitHub holds more threads or checks than one read returns.
        let threadsTruncated: Bool
        let checksTruncated: Bool

        /// The branch rule's decision, else the latest reviews' (the estate's
        /// rule: changes requested dominates, any approval counts) — a repo
        /// without a review rule still reads its approvals.
        var reviewVerdict: String? {
            if let reviewDecision { return reviewDecision }
            let states = reviews.map(\.state)
            if states.contains("CHANGES_REQUESTED") { return "CHANGES_REQUESTED" }
            if states.contains("APPROVED") { return "APPROVED" }
            return nil
        }
    }

    /// The latest opinionated review per reviewer.
    struct Review: Codable, Sendable, Equatable {
        let author: String
        /// APPROVED · CHANGES_REQUESTED · COMMENTED · DISMISSED · PENDING
        let state: String
        let submittedAt: Date?
    }

    struct Thread: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let path: String
        let line: Int?
        let isResolved: Bool
        let isOutdated: Bool
        /// The first comment's diff hunk: the lines the thread is about.
        let hunk: String
        let comments: [Comment]
    }

    struct Comment: Codable, Sendable, Equatable {
        let author: String
        let body: String
        let createdAt: Date
        let url: String
    }

    /// A check run or a commit status on the head commit.
    struct Check: Codable, Sendable, Equatable, Identifiable {
        enum Outcome: String, Codable, Sendable, Comparable {
            case failed, running, passed, skipped

            /// Failing checks lead (DESIGN.md check chips), passed ones trail.
            private var order: Int {
                switch self {
                case .failed: 0
                case .running: 1
                case .passed: 2
                case .skipped: 3
                }
            }

            static func < (lhs: Outcome, rhs: Outcome) -> Bool { lhs.order < rhs.order }
        }

        /// GitHub's node id: the same job run twice on one commit (push and
        /// pull_request) is two checks with one name.
        let nodeID: String?
        let name: String
        /// The workflow a check run belongs to; nil for a commit status.
        let workflow: String?
        let outcome: Outcome
        let url: String?
        let startedAt: Date?
        let completedAt: Date?
        /// The Actions run behind a check run — CI's object id (WP6).
        let runID: Int?

        /// Workflow and name — what a row shows and what checks sort by.
        var title: String { [workflow, name].compactMap { $0 }.joined(separator: " / ") }
        var id: String { nodeID ?? title }

        var duration: TimeInterval? {
            guard let startedAt, let completedAt else { return nil }
            return max(0, completedAt.timeIntervalSince(startedAt))
        }
    }

    /// The changed files at one `base...head`.
    struct Files: Codable, Sendable, Equatable {
        let files: [File]
        /// GitHub's compare stops at 300 files; the PR changed more.
        let truncated: Bool
    }

    struct File: Codable, Sendable, Equatable, Identifiable {
        let path: String
        let previousPath: String?
        /// added · removed · modified · renamed · copied · changed · unchanged
        let status: String
        let additions: Int
        let deletions: Int
        /// Nil for a binary file, one GitHub would not diff, or one past the
        /// patch budget (`trimmed`).
        let patch: String?
        /// The patch was cut at `patchLineLimit` or dropped past `patchByteBudget`.
        let trimmed: Bool

        var id: String { path }
    }

    /// One diff line as drawn: the gutter numbers and its kind.
    struct DiffLine: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case hunk, context, added, removed, note }

        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String

        /// A unified patch → drawn lines. A `@@ -a,b +c,d @@` header resets
        /// both counters; `\ No newline at end of file` is a note.
        static func parse(_ patch: String) -> [DiffLine] {
            var lines: [DiffLine] = []
            var old = 0
            var new = 0
            var raws = patch.split(separator: "\n", omittingEmptySubsequences: false)
            if raws.last?.isEmpty == true { raws.removeLast() } // the patch's trailing newline
            for raw in raws {
                let line = String(raw)
                if line.hasPrefix("@@") {
                    let (a, c) = hunkStarts(line)
                    old = a
                    new = c
                    lines.append(DiffLine(kind: .hunk, old: nil, new: nil, text: line))
                } else if line.hasPrefix("+") {
                    lines.append(DiffLine(kind: .added, old: nil, new: new, text: String(line.dropFirst())))
                    new += 1
                } else if line.hasPrefix("-") {
                    lines.append(DiffLine(kind: .removed, old: old, new: nil, text: String(line.dropFirst())))
                    old += 1
                } else if line.hasPrefix("\\") {
                    lines.append(DiffLine(kind: .note, old: nil, new: nil, text: line))
                } else {
                    lines.append(DiffLine(kind: .context, old: old, new: new, text: String(line.dropFirst())))
                    old += 1
                    new += 1
                }
            }
            return lines
        }

        private static func hunkStarts(_ header: String) -> (Int, Int) {
            func start(after marker: Character) -> Int {
                guard let index = header.firstIndex(of: marker) else { return 0 }
                let digits = header[header.index(after: index)...].prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
            return (start(after: "-"), start(after: "+"))
        }
    }

    /// Bounds what one PR may hold in memory and on disk (the hidden
    /// footprint budget): a file's patch keeps its first lines, and past the
    /// PR's byte budget the remaining files keep their header only.
    static let patchLineLimit = 600
    static let patchByteBudget = 384 << 10

    static let threadLimit = 50
    static let checkLimit = 100

    enum Failure: Error {
        case rateLimited
    }

    // MARK: - Conversation (GraphQL)

    static func body(repo: String, number: Int) throws -> Data {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        let query = """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
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
              }
            }
            """
        let variables: [String: Any] = ["owner": parts.first ?? repo, "name": parts.count > 1 ? parts[1] : "",
                                        "number": number]
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// Quota exhaustion arrives inside an HTTP 200 and throws `rateLimited`;
    /// a missing PR or repository is a GraphQL error, never an empty PR.
    static func decodeConversation(_ data: Data, decoder: JSONDecoder) throws -> Conversation {
        let response = try decoder.decode(Response.self, from: data)
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw Failure.rateLimited }
        guard let pr = response.data?.repository?.pullRequest else {
            throw GitHubError.graphQL(errors.first?.message ?? "pull request not found")
        }
        let threads = pr.reviewThreads.nodes.compactMap { $0 }.map { node in
            let comments = node.comments.nodes.compactMap { $0 }
            return Thread(id: node.id, path: node.path, line: node.line ?? node.originalLine,
                          isResolved: node.isResolved, isOutdated: node.isOutdated,
                          hunk: comments.first?.diffHunk ?? "",
                          comments: comments.map { Comment(author: $0.author?.login ?? "ghost", body: $0.body,
                                                           createdAt: $0.createdAt, url: $0.url) })
        }
        let rollup = pr.commits.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.contexts
        let checks = (rollup?.nodes.compactMap { $0 } ?? []).compactMap(check)
            .sorted { ($0.outcome, $0.title) < ($1.outcome, $1.title) }
        return Conversation(
            number: pr.number, title: pr.title, url: pr.url, body: pr.body, state: pr.state, isDraft: pr.isDraft,
            author: pr.author?.login, createdAt: pr.createdAt, updatedAt: pr.updatedAt, mergedAt: pr.mergedAt,
            baseRef: pr.baseRefName, headRef: pr.headRefName, baseSHA: pr.baseRefOid, headSHA: pr.headRefOid,
            additions: pr.additions, deletions: pr.deletions, changedFiles: pr.changedFiles,
            mergeable: pr.mergeable, reviewDecision: pr.reviewDecision,
            reviews: pr.latestOpinionatedReviews.nodes.compactMap { $0 }.map {
                Review(author: $0.author?.login ?? "ghost", state: $0.state, submittedAt: $0.submittedAt)
            },
            requested: pr.reviewRequests.nodes.compactMap { $0?.requestedReviewer?.name },
            threads: threads, checks: checks,
            threadsTruncated: pr.reviewThreads.totalCount > threads.count,
            checksTruncated: (rollup?.totalCount ?? 0) > checks.count)
    }

    /// A check run's status and conclusion, or a commit status's state, as
    /// one outcome. Cancelled, timed-out and action-required runs fail.
    private static func check(_ node: ContextNode) -> Check? {
        if node.typename == "StatusContext" {
            guard let context = node.context else { return nil }
            let outcome: Check.Outcome = switch node.state {
            case "SUCCESS": .passed
            case "FAILURE", "ERROR": .failed
            default: .running
            }
            return Check(nodeID: node.id, name: context, workflow: nil, outcome: outcome, url: node.targetUrl,
                         startedAt: node.createdAt, completedAt: nil, runID: nil)
        }
        guard let name = node.name else { return nil }
        let outcome: Check.Outcome
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
        return Check(nodeID: node.id, name: name, workflow: run?.workflow?.name, outcome: outcome, url: node.detailsUrl,
                     startedAt: node.startedAt, completedAt: node.completedAt, runID: run?.databaseId)
    }

    // MARK: - Files (REST compare)

    /// `?per_page=1`: only the first page carries the files, and one commit
    /// is all this read needs of the comparison's commit list.
    static func comparePath(repo: String, base: String, head: String) -> String {
        "/repos/\(repo)/compare/\(base)...\(head)?per_page=1"
    }

    /// `expected` is the conversation's `changedFiles`: GitHub's compare
    /// returns at most 300, so a larger PR reads truncated.
    static func decodeFiles(_ data: Data, expected: Int, decoder: JSONDecoder) throws -> Files {
        let compare = try decoder.decode(Compare.self, from: data)
        var spent = 0
        let files = (compare.files ?? []).map { file -> File in
            var patch = file.patch
            var trimmed = false
            if let full = patch {
                let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count > patchLineLimit {
                    patch = lines.prefix(patchLineLimit).joined(separator: "\n")
                    trimmed = true
                }
            }
            if let kept = patch {
                if spent + kept.utf8.count > patchByteBudget {
                    patch = nil
                    trimmed = true
                } else {
                    spent += kept.utf8.count
                }
            }
            return File(path: file.filename, previousPath: file.previousFilename, status: file.status,
                        additions: file.additions, deletions: file.deletions, patch: patch, trimmed: trimmed)
        }
        return Files(files: files, truncated: expected > files.count)
    }

    // MARK: - Wire

    private struct Response: Decodable {
        let data: DataNode?
        let errors: [GraphQLFailure]?
    }

    private struct GraphQLFailure: Decodable {
        let type: String?
        let message: String
    }

    private struct DataNode: Decodable {
        let repository: RepositoryNode?
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
