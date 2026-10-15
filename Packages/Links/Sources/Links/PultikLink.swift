import Foundation

/// A `pultik://` link: what another app (a status line's PR action, the agent shell's "Open
/// in Pultík"), a notification or a reference in a PR description asks Pultík's panel to
/// show.
///
/// Any web page can fire the scheme, so a link only ever selects something to look at;
/// parsing is strict and anything else is nil. The grammar is public: links in the wild
/// already use `pultik://pr/…`, so a change only ever adds.
public enum PultikLink: Hashable, Sendable {
    /// `pultik://pr/<owner>/<repo>/<number>`: the PR's detail in PRs. `repo` is
    /// `owner/name`.
    case pr(repo: String, number: Int)
    /// `pultik://panel/prod/<key>`: Prod with that deployment selected (a prod
    /// notification's click).
    case prod(key: String)
    /// `pultik://panel/<rail>`: the panel with that rail unfolded (`firing`).
    case panel(rail: String)

    /// The scheme Pultík registers (`CFBundleURLSchemes` in its `Project.swift`).
    public static let scheme = "pultik"

    public init?(_ url: URL) {
        guard let (host, parts) = LinkPath.parse(url, scheme: Self.scheme) else { return nil }
        switch (host.lowercased(), parts.count) {
        case ("pr", 3):
            guard let link = Self.pr(owner: parts[0], name: parts[1], number: parts[2]) else { return nil }
            self = link
        case ("panel", 2) where parts[0] == "prod" && Self.isKey(parts[1]):
            self = .prod(key: parts[1])
        case ("panel", 1) where Self.isKey(parts[0]):
            self = .panel(rail: parts[0])
        default:
            return nil
        }
    }

    /// The pull request a GitHub page names (`https://github.com/<owner>/<repo>/pull/<n>`,
    /// with or without a tab, query or fragment after it), as the link that opens it in
    /// Pultík.
    public init?(webURL: URL) {
        guard let components = URLComponents(url: webURL, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              ["github.com", "www.github.com"].contains(components.host?.lowercased() ?? "")
        else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull",
              let link = Self.pr(owner: parts[0], name: parts[1], number: parts[3])
        else { return nil }
        self = link
    }

    /// The link itself: `pultik://…`, each segment percent-encoded.
    public var url: URL {
        let (host, segments): (String, [String]) = switch self {
        case let .pr(repo, number):
            ("pr", repo.split(separator: "/", maxSplits: 1).map(String.init) + [String(number)])
        case let .prod(key): ("panel", ["prod", key])
        case let .panel(rail): ("panel", [rail])
        }
        // A fixed scheme and host and a rooted path always make a URL.
        return LinkPath.url(scheme: Self.scheme, host: host, segments: segments)!
    }

    /// The same PR on GitHub, for one Pultík does not hold; nil for the panel's links.
    public var webURL: URL? {
        switch self {
        case let .pr(repo, number): URL(string: "https://github.com/\(repo)/pull/\(number)")
        case .prod, .panel: nil
        }
    }

    /// A PR by its owner, repository and number: GitHub's own character sets, a number
    /// above zero.
    private static func pr(owner: String, name: String, number: String) -> PultikLink? {
        guard owner.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil,
              name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              let number = Int(number), number > 0
        else { return nil }
        return .pr(repo: "\(owner)/\(name)", number: number)
    }

    /// A deployment key or rail name: letters, digits, `.`, `_` and `-`.
    private static func isKey(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}
