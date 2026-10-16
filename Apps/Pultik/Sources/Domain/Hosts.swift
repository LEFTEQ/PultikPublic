import Foundation

/// A forge: where change requests, their conversations and their diffs come
/// from. `GitHubCodeHost` is the first; our own forge is the next adapter.
/// Every read is keyed by the credential identity that made it, and an
/// identity that no longer matches the host's credential throws rather than
/// file another account's answer under that key.
protocol CodeHost: Sendable {
    var host: HostKind { get }
    /// The digest of the credential reads go out with — a cache key, never
    /// the credential.
    func identity() async throws -> String
    /// One change request's conversation, read in the foreground.
    func changeRequest(_ ref: ChangeRequestRef, identity: String) async throws -> ChangeRequest
    /// Several at once, in the background (the warm set): a missing or
    /// unreadable one is absent from the answer, never an empty request.
    func changeRequests(_ refs: [ChangeRequestRef], identity: String) async throws -> [ChangeRequestRef: ChangeRequest]
    /// The changed files at exactly `base...head` from the host's API — the
    /// fallback when the mirror has not fetched the head yet.
    func changeSet(_ request: ChangeRequest, identity: String) async throws -> ChangeSet
    /// The https remote a git mirror fetches from, and the password git
    /// hands it — only ever through the mirror's askpass environment.
    func remoteURL(repo: String) -> URL
    /// A file at a commit on the host's own pages — a file card's ⌘↵.
    func fileURL(repo: String, sha: String, path: String, line: Int?) -> URL?
    func gitPassword(identity: String) async throws -> String?
    /// The timeline, merge options, metadata and verb handles beside the
    /// conversation (PR workbench D4, D8), read in the foreground.
    func activity(_ ref: ChangeRequestRef, identity: String) async throws -> ChangeRequestActivity
    /// The repository's labels, open milestones, assignable people and teams.
    func choices(repo: String, identity: String) async throws -> MetadataChoices
    /// Performs one verb against the activity the operator saw; throws
    /// `CodeHostFailure.rejected` with the host's message on refusal.
    func perform(_ verb: ChangeRequestVerb, on activity: ChangeRequestActivity, ref: ChangeRequestRef,
                 identity: String) async throws
}

/// A CI system: its runs, their jobs and steps, a job's log, and the one
/// mutation Pultík makes (re-run failed jobs).
protocol CIHost: Sendable {
    var host: HostKind { get }
    func identity() async throws -> String
    func run(_ ref: CIRunRef, identity: String) async throws -> CIRunDetail
    func logTail(_ ref: CIRunRef, job: CIRunJob, identity: String) async throws -> LogTail
    /// Reads the run fresh and re-runs its failed jobs only while it is still
    /// the failed attempt the operator is looking at.
    func rerunFailedIfStill(_ ref: CIRunRef, shown: CIRun, identity: String) async throws -> RerunVerdict
}
