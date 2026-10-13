import Foundation

extension StatusStore {
    /// The PR detail card's reads (WP5, stay in Pultík D9–D10), through the
    /// query repository, keyed by the credential digest that read them. The
    /// warm set keeps every change request touched in 48 h on disk, so an
    /// open answers from there; a read goes out only when the index says the
    /// request moved, or its checks are still running.
    enum PRDetailResources {
        /// Persisted and LRU-bounded (D9). Current while the index's
        /// `updatedAt` has not moved past it; a cold one revalidates after 30 s.
        static let conversation = QueryResource<ChangeRequest>(
            name: "pr.conversation", staleAfter: 30, keep: 400)
        /// Files and patches never change for a key, so the snapshot is
        /// served at any age, across relaunches. Keyed by both SHAs.
        static let files = QueryResource<ChangeSet>(
            name: "pr.files", schema: 3, staleAfter: .infinity, keep: 200)
    }

    func conversationKey(_ ref: ChangeRequestRef, identity: String) -> QueryKey {
        QueryKey(resource: PRDetailResources.conversation.name, identity: identity, scope: ref.key)
    }

    /// Exactly the compared pair, `baseSHA...headSHA`: the one key that names
    /// a single diff. The base moving costs one files read; the detail keeps
    /// the same head's last diff on screen, marked, while it runs.
    func filesKey(_ request: ChangeRequest, identity: String) -> QueryKey {
        QueryKey(resource: PRDetailResources.files.name, identity: identity,
                 scope: "\(request.ref.key)@\(request.baseSHA)...\(request.headSHA)")
    }

    /// What memory holds for `ref` under the current identity, any age — the
    /// detail draws it at once and revalidates.
    func cachedPRDetail(_ ref: ChangeRequestRef) -> (conversation: ChangeRequest?, files: ChangeSet?) {
        guard let identity = prIndexIdentity else { return (nil, nil) }
        let conversation = QueryRepository.shared.cached(ChangeRequest.self, key: conversationKey(ref, identity: identity))?.value
        return (conversation, conversation.flatMap(cachedPRFiles))
    }

    /// The files memory holds for exactly this conversation's diff — never
    /// another revision's.
    func cachedPRFiles(_ request: ChangeRequest) -> ChangeSet? {
        guard let identity = prIndexIdentity else { return nil }
        return QueryRepository.shared.cached(ChangeSet.self, key: filesKey(request, identity: identity))?.value
    }

    /// When the index last saw `ref` updated: the estate's recent PRs, the
    /// archive and the inbox all land there.
    func indexedUpdatedAt(_ ref: ChangeRequestRef) -> Date? {
        prIndex.records["\(ref.repo)#\(ref.number)".lowercased()]?.pr.updatedAt
            ?? inbox.first { $0.repoSlug.caseInsensitiveCompare(ref.repo) == .orderedSame && $0.info.pr.number == ref.number }?
            .info.pr.updatedAt
    }

    /// `WarmSet.isCurrent` against this store's index.
    func isCurrent(_ held: (value: ChangeRequest, fetchedAt: Date), now: Date = Date()) -> Bool {
        WarmSet.isCurrent(held.value, fetchedAt: held.fetchedAt, indexed: indexedUpdatedAt(held.value.ref), now: now)
    }

    /// The conversation: held and current, or read now. `force` is the CI
    /// watch's confirm read after a transition.
    func prConversation(_ ref: ChangeRequestRef, force: Bool = false) async throws -> ChangeRequest {
        let host = codeHost
        let identity = try await host.identity()
        let key = conversationKey(ref, identity: identity)
        if !force, let held = await QueryRepository.shared.held(PRDetailResources.conversation, key: key),
           isCurrent(held) {
            return held.value
        }
        let request = try await QueryRepository.shared.load(PRDetailResources.conversation, key: key, maxAge: 0) {
            try await host.changeRequest(ref, identity: identity)
        }
        warmUpdatedAt[ref] = request.updatedAt
        return request
    }

    /// The change set at exactly the conversation's `base...head`: held, or
    /// from the mirror once it has the repo (D10), else the host's compare
    /// while the mirror clones in the background.
    func prFiles(_ request: ChangeRequest) async throws -> ChangeSet {
        let host = codeHost
        let identity = try await host.identity()
        let mirrored = await GitMirror.shared.hasRepo(request.ref.repo)
        if !mirrored { warmMirror([request]) }
        return try await QueryRepository.shared.load(PRDetailResources.files, key: filesKey(request, identity: identity),
                                                     maxAge: .infinity) {
            if mirrored {
                do {
                    return try await GitMirror.shared.changeSet(
                        for: request, remote: host.remoteURL(repo: request.ref.repo),
                        password: try await host.gitPassword(identity: identity))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    NSLog("pultik: mirror diff %@ failed, reading the host's: %@", request.ref.key,
                          error.localizedDescription)
                }
            }
            return try await host.changeSet(request, identity: identity)
        }
    }
}
