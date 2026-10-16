import Foundation

/// What the workbench reads beside the conversation (PR workbench D4, D8): the
/// timeline, merge options, metadata and every handle a verb needs. One host
/// read on opening a change request; a verb re-reads it.
/// Foundation-only: the contract harness builds it.
struct ChangeRequestActivity: Codable, Sendable, Equatable {
    /// The request's own host handle; every verb addresses it.
    let nodeID: String
    /// When the host last saw the request change: the activity is current
    /// against the index's `updatedAt` exactly like the conversation.
    let updatedAt: Date
    let headSHA: String
    /// The signed-in login.
    let viewer: String
    /// Oldest first.
    let timeline: [TimelineEvent]
    /// The host holds older events than one read returns.
    let timelineTruncated: Bool
    let labels: [ChangeRequestLabel]
    let assignees: [Person]
    let milestone: Milestone?
    /// Reviewers still asked, with the handles `setReviewers` replaces them by.
    let requestedReviewers: [Person]
    let requestedTeams: [Team]
    let merge: MergeOptions
    let rights: ViewerRights
    /// The viewer's own unsubmitted review, if any.
    let pendingReview: PendingReview?
    /// Logins.
    let suggestedReviewers: [String]
}

struct Person: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let login: String
    let name: String?
    /// An app account. The pickers never offer one, so `setReviewers` keeps a
    /// requested bot only while the desired set still names it.
    var isBot = false
}

struct Team: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let slug: String
}

/// Named `ChangeRequestLabel`: a bare `Label` would shadow SwiftUI's in every view.
struct ChangeRequestLabel: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    /// Hex without `#`.
    let color: String
    let description: String?
}

struct Milestone: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let dueOn: Date?
}

enum MergeMethod: String, Codable, Sendable, CaseIterable {
    case merge, squash, rebase
}

struct MergeOptions: Codable, Sendable, Equatable {
    /// What the repository allows, in merge / squash / rebase order.
    let methods: [MergeMethod]
    /// The viewer's last method, when the repository still allows it.
    let preferred: MergeMethod?
    let autoMergeAllowed: Bool
    /// Auto-merge enabled now, with its method.
    let autoMerge: MergeMethod?
    /// The repository deletes the head branch itself after a merge.
    let deleteBranchOnMerge: Bool
    let state: MergeState
    /// Nil when the head ref is gone or lives in another repository: no
    /// branch to delete from here.
    let headRefID: String?
    /// The host had finished computing `state` and no check was still
    /// running when this was read. Until then the state can move without the
    /// request's `updatedAt` moving, so an unsettled read is never current.
    let settled: Bool
}

/// The host's merge box verdict (GitHub's `mergeStateStatus`).
enum MergeState: String, Codable, Sendable {
    case clean, behind, blocked, dirty, draft, hasHooks, unknown, unstable
}

/// What the viewer may do to this request. Merge itself has no right of its
/// own: `canUpdate` (write access) offers it, branch rules decide in `state`,
/// and `canMergeAsAdmin` may bypass them.
struct ViewerRights: Codable, Sendable, Equatable {
    let canUpdate: Bool
    let canMergeAsAdmin: Bool
    let canUpdateBranch: Bool
    /// The host offers deleting the head branch only once the request is
    /// merged or closed; merge's own `deleteBranch` does not need it.
    let canDeleteHeadRef: Bool
    let canEnableAutoMerge: Bool
    let canDisableAutoMerge: Bool
}

struct PendingReview: Codable, Sendable, Equatable {
    let id: String
    let comments: [DraftReviewComment]
}

struct TimelineEvent: Codable, Sendable, Equatable, Identifiable {
    enum Kind: Codable, Sendable, Equatable {
        case comment(body: String)
        case review(verdict: ChangeRequest.Verdict, body: String, comments: Int)
        case commit(sha: String, headline: String)
        case forcePush(before: String?, after: String?)
        case merged(sha: String?)
        case closed
        case reopened
        case readyForReview
        case convertedToDraft
        /// A user by login, a team by name.
        case reviewRequested(String)
        case labeled(String)
        case unlabeled(String)
        case assigned(String)
        case renamed(from: String, to: String)
        case baseChanged(from: String, to: String)
    }

    let id: String
    let actor: String?
    let at: Date
    let url: String?
    let kind: Kind
}

/// Repo-wide choices the metadata pickers offer, read on opening a picker.
struct MetadataChoices: Codable, Sendable, Equatable {
    let labels: [ChangeRequestLabel]
    /// Open ones, soonest due first.
    let milestones: [Milestone]
    /// Everyone the request can be assigned to — the reviewer picker's
    /// people too.
    let people: [Person]
    /// Empty where the credential cannot read the organisation's teams, or
    /// the repository belongs to a user.
    let teams: [Team]
}

enum ReviewEvent: String, Codable, Sendable {
    case approve, requestChanges, comment
}

/// One inline comment of a pending review: `line` on `side`, or the range
/// `startLine…line` when `startLine` is set.
struct DraftReviewComment: Codable, Sendable, Equatable {
    /// Left is the base, right the head.
    enum Side: String, Codable, Sendable {
        case left, right
    }

    /// The host's handle once it holds the comment; nil for a new one.
    var id: String?
    var path: String
    var line: Int
    var side: Side
    var startLine: Int?
    var startSide: Side?
    var body: String
}

/// One change-request mutation (PR workbench D4). The view confirms merge and
/// close first (D5).
enum ChangeRequestVerb: Sendable, Equatable {
    /// Refused when the head moved past `expectedHead`.
    case merge(MergeMethod, expectedHead: String, deleteBranch: Bool)
    case enableAutoMerge(MergeMethod)
    case disableAutoMerge
    case updateBranch(rebase: Bool, expectedHead: String)
    case close
    case reopen
    case markReady
    case convertToDraft
    case deleteBranch
    case comment(String)
    case reply(thread: String, body: String)
    case resolve(thread: String)
    case unresolve(thread: String)
    /// Nil leaves that field as it is.
    case edit(title: String?, body: String?)
    /// Into the viewer's pending review, created on the first one.
    case addReviewComment(DraftReviewComment)
    /// The pending review if any, else a fresh review.
    case submitReview(ReviewEvent, body: String)
    case discardPendingReview
    /// Node ids; the full desired set.
    case setReviewers(users: [String], teams: [String])
    /// Node ids; the full desired set.
    case setAssignees([String])
    /// Node ids; the full desired set.
    case setLabels([String])
    case setMilestone(Milestone?)
}

/// The host refused a verb, in its own words — shown to the operator as-is.
enum CodeHostFailure: Error, LocalizedError, Equatable {
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        }
    }
}
