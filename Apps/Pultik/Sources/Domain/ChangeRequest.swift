import CodeCore
import Foundation

/// A change request as Pultík reads it: everything about it that can change
/// without a push — description, reviews, review threads and checks on the
/// head commit. A host adapter fills it (`CodeHost`); the detail card, the
/// warm set and autolinks read only this.
struct ChangeRequest: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case open, closed, merged
    }

    enum Mergeability: String, Codable, Sendable {
        case mergeable, conflicting, unknown
    }

    /// A review's opinion, and the branch rule's overall decision.
    enum Verdict: String, Codable, Sendable {
        case approved, changesRequested, reviewRequired, commented, dismissed, pending
    }

    let ref: ChangeRequestRef
    let title: String
    let url: String
    let body: String
    let state: State
    let isDraft: Bool
    let author: String?
    let createdAt: Date
    let updatedAt: Date
    let mergedAt: Date?
    let baseRef: String
    let headRef: String
    /// The files key: the diff is `baseSHA...headSHA`, the merge base
    /// against the head, exactly the host's "Files changed" — and the pair
    /// names one diff for good.
    let baseSHA: String
    let headSHA: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let mergeable: Mergeability
    /// The branch rule's decision; nil where the repo has no review rule.
    let decision: Verdict?
    /// The latest opinionated review per reviewer.
    let reviews: [Review]
    /// Reviewers still asked, users by login and teams by name.
    let requested: [String]
    let threads: [ReviewThread]
    let checks: [Check]
    /// The host holds more threads or checks than one read returns.
    let threadsTruncated: Bool
    let checksTruncated: Bool

    var number: Int { ref.number }

    /// The branch rule's decision, else the latest reviews' (the estate's
    /// rule: changes requested dominates, any approval counts) — a repo
    /// without a review rule still reads its approvals.
    var reviewVerdict: Verdict? {
        if let decision { return decision }
        let verdicts = reviews.map(\.verdict)
        if verdicts.contains(.changesRequested) { return .changesRequested }
        if verdicts.contains(.approved) { return .approved }
        return nil
    }

    var openThreads: [ReviewThread] { threads.filter { !$0.isResolved } }

    struct Review: Codable, Sendable, Equatable {
        let author: String
        let verdict: Verdict
        let submittedAt: Date?
    }

    struct ReviewThread: Codable, Sendable, Equatable, Identifiable {
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

    /// A CI job (or a plain commit status) on the head commit.
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

        /// The host's node id: the same job run twice on one commit (push and
        /// pull_request) is two checks with one name.
        let nodeID: String?
        let name: String
        /// The workflow a job belongs to; nil for a commit status.
        let workflow: String?
        let outcome: Outcome
        let url: String?
        let startedAt: Date?
        let completedAt: Date?
        /// The CI run behind the job — its run card's id.
        let runID: Int?

        /// Workflow and name — what a row shows and what checks sort by.
        var title: String { [workflow, name].compactMap { $0 }.joined(separator: " / ") }
        var id: String { nodeID ?? title }

        var duration: TimeInterval? {
            guard let startedAt, let completedAt else { return nil }
            return max(0, completedAt.timeIntervalSince(startedAt))
        }
    }
}

/// The changed files of one `base...head`.
struct ChangeSet: Codable, Sendable, Equatable {
    let files: [ChangedFile]
    /// The source stopped listing before the change request's last file.
    let truncated: Bool
}

struct ChangedFile: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case added, removed, modified, renamed, copied, changed, unchanged
    }

    let path: String
    let previousPath: String?
    let status: Status
    let additions: Int
    let deletions: Int
    /// Nil for a binary file, one the source would not diff, or one past
    /// the patch budget (`trimmed`).
    let patch: String?
    /// The patch was cut at its source's line limit or dropped past its
    /// byte budget (`ChangeSet.bounded`).
    let trimmed: Bool
    /// Each side's blob, where the source names them (the mirror's
    /// `--full-index`): highlighting parses the whole file, and caches it
    /// per blob across every change request (PR workbench WP2).
    var oldBlob: String? = nil
    var newBlob: String? = nil

    var id: String { path }
}

extension ChangeSet {
    /// Bounds what one change request may hold in memory and on disk (the
    /// hidden footprint budget): a file's patch keeps its first lines, and
    /// past the byte budget the remaining files keep their header only.
    /// These are the host API's (P4); the mirror's diff draws on the code
    /// canvas, which costs only the rows on screen, so it keeps far more.
    static let patchLineLimit = 600
    static let patchByteBudget = 384 << 10
    static let mirrorLineLimit = 20_000
    static let mirrorByteBudget = 6 << 20

    /// Applies the host API's budgets to patches in drawn order.
    static func bounded(_ files: [(path: String, previousPath: String?, status: ChangedFile.Status,
                                   additions: Int, deletions: Int, patch: String?)],
                        truncated: Bool) -> ChangeSet {
        bounded(files.map {
            ChangedFile(path: $0.path, previousPath: $0.previousPath, status: $0.status, additions: $0.additions,
                        deletions: $0.deletions, patch: $0.patch, trimmed: false)
        }, truncated: truncated, lineLimit: patchLineLimit, byteBudget: patchByteBudget)
    }

    /// Applies `lineLimit` and `byteBudget` to patches in drawn order.
    static func bounded(_ files: [ChangedFile], truncated: Bool, lineLimit: Int, byteBudget: Int) -> ChangeSet {
        var spent = 0
        let kept = files.map { file -> ChangedFile in
            var patch = file.patch
            var trimmed = file.trimmed
            if let full = patch {
                let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count > lineLimit {
                    patch = lines.prefix(lineLimit).joined(separator: "\n")
                    trimmed = true
                }
            }
            if let body = patch {
                if spent + body.utf8.count > byteBudget {
                    patch = nil
                    trimmed = true
                } else {
                    spent += body.utf8.count
                }
            }
            return ChangedFile(path: file.path, previousPath: file.previousPath, status: file.status,
                               additions: file.additions, deletions: file.deletions, patch: patch, trimmed: trimmed,
                               oldBlob: file.oldBlob, newBlob: file.newBlob)
        }
        return ChangeSet(files: kept, truncated: truncated)
    }
}

/// One diff line as drawn: the gutter numbers and its kind. `DiffLine.parse`
/// turns a unified patch into drawn lines: a `@@ -a,b +c,d @@` header resets
/// both counters, `\ No newline at end of file` is a note (the code core's,
/// workbench WP3b).
typealias DiffLine = CodeCore.DiffLine

/// The inbox read lists this many open change requests per repo, most
/// recently updated first: a repo that fills it may hold more, so nothing
/// may read its list as complete.
enum ChangeRequestInbox {
    static let openLimit = 5
}
