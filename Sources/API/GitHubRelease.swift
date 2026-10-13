import Foundation

/// A deployment's release line (copilot shell WP7, Shipping inside Prod — D9):
/// what a GitHub environment runs against what its branch holds. Hlídač's
/// digest carries no release data, so this is two foreground GraphQL reads
/// on explicit selection, never polled: the environment's recent
/// deployments, then the branch's head, how far it is past the live commit
/// (`Ref.compare`) and its newest commits. A REST compare would carry up to
/// 300 files of patches (773 KB for one ExampleApp release); the comparison
/// carries none.
enum GitHubRelease {
    /// The release line is Pultík's (`Sources/Domain/Release.swift`); these
    /// names keep the adapter's wire code short.
    typealias Source = ReleaseSource
    typealias Deploy = ReleaseDeploy
    typealias Commit = ReleaseCommit
    typealias Line = ReleaseLine

    static let deploymentLimit = ReleaseLine.deploymentLimit
    static let commitLimit = ReleaseLine.commitLimit

    enum Failure: Error {
        case rateLimited
    }

    // MARK: - Deployments (GraphQL)

    static func deploymentsBody(_ source: Source) throws -> Data {
        let query = """
            query($owner: String!, $name: String!, $environment: String!) {
              repository(owner: $owner, name: $name) {
                defaultBranchRef { name }
                deployments(environments: [$environment], first: \(deploymentLimit),
                            orderBy: {field: CREATED_AT, direction: DESC}) {
                  nodes { databaseId commitOid createdAt ref { name } creator { login }
                    latestStatus { state createdAt environmentUrl logUrl } }
                }
              }
            }
            """
        return try body(query, source: source, extra: ["environment": source.environment])
    }

    /// The environment's deployments and the branch the line compares.
    struct Deployments: Sendable, Equatable {
        let branch: String
        let live: Deploy?
        let latest: Deploy?
    }

    static func decodeDeployments(_ data: Data, source: Source, decoder: JSONDecoder) throws -> Deployments {
        let repository = try repository(data, decoder: decoder)
        let deploys = (repository.deployments?.nodes ?? []).compactMap { $0 }.compactMap { node -> Deploy? in
            guard let id = node.databaseId else { return nil }
            return Deploy(id: id, sha: node.commitOid, ref: node.ref?.name, createdAt: node.createdAt,
                          state: node.latestStatus?.state.lowercased() ?? "pending",
                          stateAt: node.latestStatus?.createdAt, creator: node.creator?.login,
                          url: node.latestStatus?.environmentUrl ?? node.latestStatus?.logUrl)
        }
        let live = deploys.first { ["success", "inactive"].contains($0.state) }
        let newest = deploys.first
        let branch = source.branch ?? newest?.ref ?? repository.defaultBranchRef?.name ?? "main"
        return Deployments(branch: branch, live: live, latest: newest?.id == live?.id ? nil : newest)
    }

    // MARK: - Branch (GraphQL)

    static func branchBody(_ source: Source, branch: String, live: String?) throws -> Data {
        let query = """
            query($owner: String!, $name: String!, $qualified: String!, $live: String!, $compares: Boolean!) {
              repository(owner: $owner, name: $name) {
                ref(qualifiedName: $qualified) {
                  compare(headRef: $live) @include(if: $compares) { aheadBy behindBy }
                  target { oid ... on Commit { history(first: \(commitLimit)) {
                    nodes { oid messageHeadline committedDate author { name user { login } } } } } }
                }
              }
            }
            """
        return try body(query, source: source, extra: ["qualified": "refs/heads/\(branch)", "live": live ?? "",
                                                       "compares": live != nil])
    }

    /// The comparison is base = branch, head = live: what the branch has
    /// that the live commit lacks is its `behindBy`. The history is cut at
    /// the live commit and at the count, so a commit already live is never
    /// listed as waiting.
    static func decodeLine(_ data: Data, source: Source, deployments: Deployments,
                           decoder: JSONDecoder) throws -> Line {
        let ref = try repository(data, decoder: decoder).ref
        let history = ref?.target.history?.nodes.compactMap { $0 } ?? []
        let waiting = ref?.compare?.behindBy
        let liveSHA = deployments.live?.sha
        let commits = history.prefix { $0.oid != liveSHA }.prefix(waiting ?? 0).map {
            Commit(sha: $0.oid, headline: $0.messageHeadline, author: $0.author?.user?.login ?? $0.author?.name,
                   committedAt: $0.committedDate)
        }
        return Line(source: source, branch: deployments.branch, live: deployments.live, latest: deployments.latest,
                    branchHead: ref?.target.oid, waiting: deployments.live == nil ? nil : waiting,
                    ahead: ref?.compare?.aheadBy, commits: Array(commits))
    }

    // MARK: - Wire

    private static func body(_ query: String, source: Source, extra: [String: Any]) throws -> Data {
        let parts = source.repo.split(separator: "/", maxSplits: 1).map(String.init)
        var variables: [String: Any] = ["owner": parts.first ?? source.repo, "name": parts.count > 1 ? parts[1] : ""]
        variables.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// Quota exhaustion arrives inside an HTTP 200 and throws `rateLimited`;
    /// a missing repository is a GraphQL error, never an empty line.
    private static func repository(_ data: Data, decoder: JSONDecoder) throws -> RepositoryNode {
        let response = try decoder.decode(Response.self, from: data)
        let errors = response.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { throw Failure.rateLimited }
        guard let repository = response.data?.repository else {
            throw GitHubError.graphQL(errors.first?.message ?? "repository not found")
        }
        return repository
    }

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
        let defaultBranchRef: Named?
        let deployments: Connection<DeploymentNode>?
        let ref: RefNode?
    }

    private struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node?]
    }

    private struct Named: Decodable {
        let name: String
    }

    private struct DeploymentNode: Decodable {
        let databaseId: Int?
        let commitOid: String
        let createdAt: Date
        let ref: Named?
        let creator: Login?
        let latestStatus: Status?

        struct Login: Decodable { let login: String }
        struct Status: Decodable {
            let state: String
            let createdAt: Date?
            let environmentUrl: String?
            let logUrl: String?
        }
    }

    private struct RefNode: Decodable {
        let compare: Comparison?
        let target: Target

        struct Comparison: Decodable {
            let aheadBy: Int
            let behindBy: Int
        }

        struct Target: Decodable {
            let oid: String
            let history: Connection<CommitNode>?
        }
    }

    private struct CommitNode: Decodable {
        let oid: String
        let messageHeadline: String
        let committedDate: Date
        let author: Author?

        struct Author: Decodable {
            let name: String?
            let user: DeploymentNode.Login?
        }
    }
}

extension ReleaseLine {
    /// The environment's deployments page on GitHub.
    var deploymentsURL: URL? {
        URL(string: "https://github.com/\(source.repo)/deployments/\(source.environment)")
    }
}
