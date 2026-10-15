import Foundation

/// A link to one agent session in the agent shell that registers `scheme`:
/// `<scheme>://session/<session>`. `session` names the session the way the caller knows
/// it: the shell's agent id or name, or the harness's own session id (Claude's
/// `session_id`), which another app (Pultík's Sessions) already holds. The shell resolves it.
///
/// The scheme is the shell's brand, so it is never written here: the app that owns the
/// brand passes it in (the shell from its brand file; Pultík from its Info.plist, which its
/// manifest fills from that file). Links names no shell, so it publishes with Pultík.
public struct SessionLink: Hashable, Sendable {
    /// The link's host: `<scheme>://session/…`.
    public static let host = "session"
    /// Longest session reference a link carries, in Unicode scalars.
    public static let maxSessionLength = 256

    /// The shell's URL scheme, lowercased.
    public let scheme: String
    /// The session reference, decoded.
    public let session: String

    /// Nil when `scheme` is not a URL scheme, or `session` is empty, padded with whitespace,
    /// longer than `maxSessionLength` or holds a control character.
    public init?(scheme: String, session: String) {
        guard Self.isScheme(scheme), Self.isSession(session) else { return nil }
        self.scheme = scheme.lowercased()
        self.session = session
    }

    /// `url` when it is exactly `<scheme>://session/<one segment>`.
    public init?(_ url: URL, scheme: String) {
        guard let (host, parts) = LinkPath.parse(url, scheme: scheme),
              host.lowercased() == Self.host, parts.count == 1
        else { return nil }
        self.init(scheme: scheme, session: parts[0])
    }

    /// The link itself, the session percent-encoded.
    public var url: URL {
        // A valid scheme, a fixed host and a rooted path always make a URL.
        LinkPath.url(scheme: scheme, host: Self.host, segments: [session])!
    }

    /// RFC 3986: a letter, then letters, digits, `+`, `-` and `.`.
    private static func isScheme(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil
    }

    private static func isSession(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.count <= maxSessionLength
            && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && text.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
