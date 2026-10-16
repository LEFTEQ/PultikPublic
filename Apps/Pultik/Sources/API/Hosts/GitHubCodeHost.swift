import Foundation

/// GitHub as Pultík's first forge (stay in Pultík N2): the `CodeHost` the
/// detail card, the warm set and the mirror read through. Every request
/// still goes through `GitHubClient` — its queue, budget and the identity
/// check that keeps one account's answer out of another's cache.
struct GitHubCodeHost: CodeHost {
    let client: GitHubClient

    var host: HostKind { .github }

    func identity() async throws -> String {
        try await client.cacheIdentity()
    }

    func changeRequest(_ ref: ChangeRequestRef, identity: String) async throws -> ChangeRequest {
        try await client.prConversation(ref, identity: identity)
    }

    /// Chunked to `GitHubPRDetail.batchSize` per query, in order. A deferral
    /// stops the remaining chunks and keeps what already landed.
    func changeRequests(_ refs: [ChangeRequestRef], identity: String) async throws -> [ChangeRequestRef: ChangeRequest] {
        var answer: [ChangeRequestRef: ChangeRequest] = [:]
        for start in stride(from: 0, to: refs.count, by: GitHubPRDetail.batchSize) {
            let chunk = Array(refs[start ..< min(start + GitHubPRDetail.batchSize, refs.count)])
            do {
                answer.merge(try await client.prConversations(chunk, identity: identity)) { $1 }
            } catch GitHubError.deferred(let until) {
                if answer.isEmpty { throw GitHubError.deferred(until) }
                return answer
            }
        }
        return answer
    }

    func changeSet(_ request: ChangeRequest, identity: String) async throws -> ChangeSet {
        try await client.prFiles(request, identity: identity)
    }

    func remoteURL(repo: String) -> URL {
        URL(string: "https://github.com/\(repo).git")!
    }

    func fileURL(repo: String, sha: String, path: String, line: Int?) -> URL? {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://github.com/\(repo)/blob/\(sha)/\(escaped)" + (line.map { "#L\($0)" } ?? ""))
    }

    func gitPassword(identity: String) async throws -> String? {
        try await client.gitPassword(identity: identity)
    }

    func activity(_ ref: ChangeRequestRef, identity: String) async throws -> ChangeRequestActivity {
        try await client.prActivity(ref, identity: identity)
    }

    func choices(repo: String, identity: String) async throws -> MetadataChoices {
        try await client.prChoices(repo: repo, identity: identity)
    }

    /// The verb's steps in order (a merge, then its branch). GitHub's refusal
    /// — a GraphQL error or a 4xx's message — is `CodeHostFailure.rejected`,
    /// after what earlier steps already did; a quota deferral, a 5xx or a
    /// transport failure passes through unchanged.
    func perform(_ verb: ChangeRequestVerb, on activity: ChangeRequestActivity, ref: ChangeRequestRef,
                 identity: String) async throws {
        for step in try GitHubPRMutations.steps(verb, on: activity, ref: ref) {
            do {
                try await client.mutate(step, identity: identity)
            } catch let refusal as GitHubPRMutations.Refusal {
                throw step.refused(refusal.message)
            } catch CodeHostFailure.rejected(let message) {
                throw step.refused(message)
            }
        }
    }
}
