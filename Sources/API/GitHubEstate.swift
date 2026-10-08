import Foundation

/// One GraphQL read per chunk of repositories replaces the per-repo REST
/// fan-out (pulls, check-runs, reviews, deployments, deployment statuses):
/// the inbox, the deploy chips and a delta of recently updated PRs that keeps
/// the search index current. Workflow runs stay on REST — GraphQL has no run list.
enum GitHubEstate {
    struct Repo {
        var prs: [PRInfo] = []
        var deploys: [DeployInfo] = []
        var recent: [ArchivedPR] = []
        var error: String?
    }

    struct Answer {
        var repos: [String: Repo]
        /// GitHub reports GraphQL quota exhaustion inside an HTTP 200.
        var rateLimited: Bool
    }

    static let recentLimit = 20
    static let chunkSize = 12

    /// Owners and names travel as variables, never spliced into the query text.
    static func body(for repos: [String]) throws -> Data {
        var declarations: [String] = []
        var selections: [String] = []
        var variables: [String: String] = [:]
        for (index, slug) in repos.enumerated() {
            let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
            declarations.append("$o\(index): String!, $n\(index): String!")
            selections.append("r\(index): repository(owner: $o\(index), name: $n\(index)) { ...estate }")
            variables["o\(index)"] = parts.first ?? slug
            variables["n\(index)"] = parts.count > 1 ? parts[1] : ""
        }
        let query = """
            query(\(declarations.joined(separator: ", "))) {
              \(selections.joined(separator: "\n  "))
            }
            fragment estate on Repository {
              open: pullRequests(states: OPEN, first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) {
                nodes {
                  databaseId number title url isDraft updatedAt headRefName headRefOid
                  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
                  latestOpinionatedReviews(first: 20) { nodes { state } }
                }
              }
              recent: pullRequests(first: \(recentLimit), orderBy: {field: UPDATED_AT, direction: DESC}) {
                nodes { number title url state isDraft mergedAt updatedAt headRefName }
              }
              deployments(first: 10, orderBy: {field: CREATED_AT, direction: DESC}) {
                nodes { databaseId environment createdAt commitOid ref { name } latestStatus { state environmentUrl logUrl } }
              }
            }
            """
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// A null repository is that repo's error (renamed away, no access); the
    /// others still answer. No `data` at all is the whole read failing.
    static func decode(_ data: Data, repos: [String], decoder: JSONDecoder) throws -> Answer {
        let response = try decoder.decode(Response.self, from: data)
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            return Answer(repos: [:], rateLimited: true)
        }
        guard let nodes = response.data else {
            throw GitHubError.graphQL(errors.first?.message ?? "no data")
        }
        var answer: [String: Repo] = [:]
        for (index, slug) in repos.enumerated() {
            let alias = "r\(index)"
            guard let node = nodes[alias] ?? nil else {
                let message = errors.first { $0.path?.first?.value == alias }?.message
                answer[slug] = Repo(error: "GitHub GraphQL: \(message ?? "repository not found")")
                continue
            }
            answer[slug] = repo(node, slug: slug)
        }
        return Answer(repos: answer, rateLimited: false)
    }

    private static func repo(_ node: RepoNode, slug: String) -> Repo {
        let prs = node.open.nodes.compactMap { $0 }.map { pr in
            PRInfo(pr: PullRequest(id: pr.databaseId ?? pr.number, number: pr.number, title: pr.title,
                                   htmlUrl: pr.url, draft: pr.isDraft,
                                   head: .init(sha: pr.headRefOid, ref: pr.headRefName), updatedAt: pr.updatedAt),
                   state: checkState(pr.commits.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state),
                   review: reviewState(pr.latestOpinionatedReviews?.nodes.compactMap { $0?.state } ?? []))
        }
        let recent = node.recent.nodes.compactMap { $0 }.map { pr in
            ArchivedPR(lookup: PRLookup(number: pr.number, title: pr.title, htmlUrl: pr.url,
                                        state: pr.state.lowercased(), draft: pr.isDraft, mergedAt: pr.mergedAt,
                                        updatedAt: pr.updatedAt, head: .init(sha: "", ref: pr.headRefName)),
                       repoSlug: slug)
        }
        let latestPerEnv = Dictionary(grouping: node.deployments.nodes.compactMap { $0 }) { $0.environment ?? "" }
            .compactMap { $0.value.max { $0.createdAt < $1.createdAt } }
            .sorted { $0.createdAt > $1.createdAt }
        let deploys = latestPerEnv.prefix(4).compactMap { deployment -> DeployInfo? in
            guard let id = deployment.databaseId else { return nil }
            return DeployInfo(
                deployment: Deployment(id: id, environment: deployment.environment ?? "",
                                       ref: deployment.ref?.name ?? String(deployment.commitOid.prefix(7)),
                                       createdAt: deployment.createdAt),
                state: deployment.latestStatus?.state.lowercased() ?? "pending",
                url: deployment.latestStatus?.environmentUrl ?? deployment.latestStatus?.logUrl)
        }
        return Repo(prs: prs, deploys: deploys, recent: recent)
    }

    /// The head commit's rollup covers check runs and commit statuses alike.
    static func checkState(_ rollup: String?) -> CheckState {
        switch rollup {
        case nil: return .none
        case "SUCCESS": return .success
        case "FAILURE", "ERROR": return .failure
        default: return .running // PENDING, EXPECTED
        }
    }

    /// Latest opinionated review per reviewer: changes requested dominates,
    /// any approval counts, otherwise awaiting.
    static func reviewState(_ states: [String]) -> ReviewState {
        if states.contains("CHANGES_REQUESTED") { return .changesRequested }
        if states.contains("APPROVED") { return .approved }
        return .awaiting
    }

    private struct Response: Decodable {
        let data: [String: RepoNode?]?
        let errors: [Failure]?
    }

    private struct Failure: Decodable {
        let type: String?
        let message: String
        let path: [PathKey]?
    }

    /// GraphQL error paths mix field names and list indices.
    private struct PathKey: Decodable {
        let value: String?
        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    private struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node?]
    }

    private struct RepoNode: Decodable {
        let open: Connection<OpenPR>
        let recent: Connection<RecentPR>
        let deployments: Connection<DeploymentNode>
    }

    private struct OpenPR: Decodable {
        let databaseId: Int?
        let number: Int
        let title: String
        let url: String
        let isDraft: Bool
        let updatedAt: Date
        let headRefName: String
        let headRefOid: String
        let commits: Connection<CommitNode>
        let latestOpinionatedReviews: Connection<ReviewNode>?
    }

    private struct CommitNode: Decodable {
        let commit: Commit
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let state: String }
    }

    private struct ReviewNode: Decodable {
        let state: String
    }

    private struct RecentPR: Decodable {
        let number: Int
        let title: String
        let url: String
        let state: String // OPEN | CLOSED | MERGED
        let isDraft: Bool
        let mergedAt: Date?
        let updatedAt: Date
        let headRefName: String
    }

    private struct DeploymentNode: Decodable {
        let databaseId: Int?
        let environment: String?
        let createdAt: Date
        let commitOid: String
        let ref: Ref?
        let latestStatus: Status?
        struct Ref: Decodable { let name: String }
        struct Status: Decodable {
            let state: String
            let environmentUrl: String?
            let logUrl: String?
        }
    }
}
