import Foundation

/// Where a deployment's release is read: a repository's deploy environment
/// and the branch it deploys from (nil = the newest deployment's own ref,
/// else the default branch).
struct ReleaseSource: Codable, Hashable, Sendable {
    let repo: String
    let environment: String
    var branch: String?
}

struct ReleaseDeploy: Codable, Sendable, Equatable {
    let id: Int
    let sha: String
    let ref: String?
    let createdAt: Date
    /// The latest status, lowercased: success, failure, error, in_progress,
    /// queued, pending, inactive.
    let state: String
    let stateAt: Date?
    let creator: String?
    let url: String?

    var short: String { String(sha.prefix(7)) }
    var isFailed: Bool { ["failure", "error"].contains(state) }
}

struct ReleaseCommit: Codable, Sendable, Equatable, Identifiable {
    let sha: String
    let headline: String
    let author: String?
    let committedAt: Date
    var id: String { sha }
    var short: String { String(sha.prefix(7)) }
}

/// A deployment's release line: what its environment runs against what its
/// branch holds.
struct ReleaseLine: Codable, Sendable, Equatable {
    let source: ReleaseSource
    /// The branch compared: the source's, else what the environment
    /// deploys from.
    let branch: String
    /// The newest deployment whose status is success (or since made
    /// inactive by a newer success): what runs.
    let live: ReleaseDeploy?
    /// The newest deployment when it is not the live one — in flight or
    /// failed.
    let latest: ReleaseDeploy?
    let branchHead: String?
    /// Commits on `branch` the live commit lacks; nil = not known (no live
    /// deployment, or the branch is gone).
    let waiting: Int?
    /// Commits the live one carries that `branch` does not (a hotfix
    /// deployed from elsewhere).
    let ahead: Int?
    /// The newest waiting commits, newest first, at most `commitLimit`.
    let commits: [ReleaseCommit]

    static let deploymentLimit = 10
    static let commitLimit = 8
}
