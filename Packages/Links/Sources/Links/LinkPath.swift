import Foundation

/// A link's path as segments: percent-encoded one segment at a time, so a `/` inside a value
/// stays inside it.
enum LinkPath {
    /// RFC 3986's unreserved characters: the only ones a segment carries as they are.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// `scheme://host/segment/…`, each segment percent-encoded.
    static func url(scheme: String, host: String, segments: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        // A Swift string is always valid Unicode, so encoding cannot fail.
        components.percentEncodedPath = segments
            .map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "") }
            .joined()
        return components.url
    }

    /// `url`'s host and decoded path segments when its scheme is `scheme` (any case). Empty
    /// segments (`//`, a trailing `/`) are dropped; nil when a segment is not valid
    /// percent-encoding.
    static func parse(_ url: URL, scheme: String) -> (host: String, segments: [String])? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme.lowercased(),
              let host = components.host
        else { return nil }
        var segments: [String] = []
        for raw in components.percentEncodedPath.split(separator: "/") {
            guard let segment = raw.removingPercentEncoding else { return nil }
            segments.append(segment)
        }
        return (host, segments)
    }
}
