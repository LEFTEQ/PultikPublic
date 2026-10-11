import Foundation

/// One PR as the PRs module reads it: a repo and a number — inbox and
/// archive rows alike.
struct PRRef: Hashable, Sendable {
    let repo: String
    let number: Int
}

extension StatusStore {
    /// The PR detail reads (WP5), through the query repository: explicit
    /// selection only (D8), keyed by the GitHub credential digest that read
    /// them, never polled.
    enum PRDetailResources {
        /// What moves without a push. Fresh for 30 s; memory only.
        static let conversation = QueryResource<GitHubPRDetail.Conversation>(
            name: "github.pr.conversation", staleAfter: 30, persists: false, keep: 24)
        /// Files and patches never change for a key, so the snapshot is
        /// served at any age, across relaunches. Schema 2: keyed by both SHAs.
        static let files = QueryResource<GitHubPRDetail.Files>(
            name: "github.pr.files", schema: 2, staleAfter: .infinity, keep: 12)
    }

    private func conversationKey(_ ref: PRRef, identity: String) -> QueryKey {
        QueryKey(resource: PRDetailResources.conversation.name, identity: identity, scope: "\(ref.repo)#\(ref.number)")
    }

    /// Exactly the compared pair, `baseSHA...headSHA`: the one key that names
    /// a single diff. The base moving costs one files read; the detail keeps
    /// the same head's last diff on screen, marked, while it runs.
    private func filesKey(_ ref: PRRef, of conversation: GitHubPRDetail.Conversation, identity: String) -> QueryKey {
        QueryKey(resource: PRDetailResources.files.name, identity: identity,
                 scope: "\(ref.repo)#\(ref.number)@\(conversation.baseSHA)...\(conversation.headSHA)")
    }

    /// What memory holds for `ref` under the current identity, any age — the
    /// detail draws it at once and revalidates.
    func cachedPRDetail(_ ref: PRRef) -> (conversation: GitHubPRDetail.Conversation?, files: GitHubPRDetail.Files?) {
        guard let identity = prIndexIdentity else { return (nil, nil) }
        let conversation = QueryRepository.shared.cached(GitHubPRDetail.Conversation.self,
                                                         key: conversationKey(ref, identity: identity))?.value
        return (conversation, conversation.flatMap { cachedPRFiles(ref, of: $0) })
    }

    /// The files memory holds for exactly this conversation's diff — never
    /// another revision's.
    func cachedPRFiles(_ ref: PRRef, of conversation: GitHubPRDetail.Conversation) -> GitHubPRDetail.Files? {
        guard let identity = prIndexIdentity else { return nil }
        return QueryRepository.shared.cached(GitHubPRDetail.Files.self,
                                             key: filesKey(ref, of: conversation, identity: identity))?.value
    }

    func prConversation(_ ref: PRRef, maxAge: TimeInterval = PRDetailResources.conversation.staleAfter)
        async throws -> GitHubPRDetail.Conversation {
        let identity = try await client.cacheIdentity()
        return try await QueryRepository.shared.load(PRDetailResources.conversation,
                                                     key: conversationKey(ref, identity: identity),
                                                     maxAge: maxAge) { [client] in
            try await client.prConversation(repo: ref.repo, number: ref.number, identity: identity)
        }
    }

    func prFiles(_ ref: PRRef, of conversation: GitHubPRDetail.Conversation) async throws -> GitHubPRDetail.Files {
        let identity = try await client.cacheIdentity()
        return try await QueryRepository.shared.load(PRDetailResources.files,
                                                     key: filesKey(ref, of: conversation, identity: identity),
                                                     maxAge: .infinity) { [client] in
            try await client.prFiles(repo: ref.repo, base: conversation.baseSHA, head: conversation.headSHA,
                                     changedFiles: conversation.changedFiles, identity: identity)
        }
    }
}
