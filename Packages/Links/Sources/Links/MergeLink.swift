import Foundation

/// A link asking the agent shell that registers `scheme` to resolve a pull request's merge
/// (vt-7968, decision M3): `<scheme>://merge/<owner>/<repo>/<number>`. Pultík's merge preview is
/// read only; resolving needs a worktree and an editor, which the shell owns. Like
/// [`SessionLink`], the scheme is passed in by the app that owns the brand.
public struct MergeLink: Hashable, Sendable {
    /// The link's host: `<scheme>://merge/…`.
    public static let host = "merge"

    /// The shell's URL scheme, lowercased.
    public let scheme: String
    /// `owner/name`.
    public let repo: String
    public let number: Int

    /// Nil when `scheme` is not a URL scheme, `repo` is not `owner/name` or `number` is not
    /// positive.
    public init?(scheme: String, repo: String, number: Int) {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard scheme.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil,
              parts.count == 2, parts.allSatisfy(Self.isName), number > 0
        else { return nil }
        self.scheme = scheme.lowercased()
        self.repo = repo
        self.number = number
    }

    /// `url` when it is exactly `<scheme>://merge/<owner>/<repo>/<number>`.
    public init?(_ url: URL, scheme: String) {
        guard let (host, parts) = LinkPath.parse(url, scheme: scheme),
              host.lowercased() == Self.host, parts.count == 3, let number = Int(parts[2])
        else { return nil }
        self.init(scheme: scheme, repo: "\(parts[0])/\(parts[1])", number: number)
    }

    public var url: URL {
        let parts = repo.split(separator: "/").map(String.init)
        // A valid scheme, a fixed host and a rooted path always make a URL.
        return LinkPath.url(scheme: scheme, host: Self.host, segments: parts + [String(number)])!
    }

    /// A GitHub owner or repository name: letters, digits, `-`, `_` and `.`.
    private static func isName(_ part: Substring) -> Bool {
        !part.isEmpty && part.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}
