import Foundation

/// A reference in prose that Pultík links itself (stay in Pultík D8):
/// `#123` (in the change request's own repo), `owner/repo#123`, `@user` and
/// a commit SHA. Parsing is host-neutral; where a reference opens is the
/// host adapter's (`AutolinkResolver`) — Pultík's own detail when its
/// indexes hold the object, else the host's page.
enum AutolinkReference: Equatable, Sendable {
    case changeRequest(ChangeRequestRef)
    case user(String)
    case commit(repo: String, sha: String)
}

protocol AutolinkResolver {
    /// Where `reference` opens; nil leaves the text as written.
    func url(for reference: AutolinkReference) -> URL?
}

/// Finds the references in one run of plain text (never inside code or an
/// existing link — the renderer only hands it text nodes). Foundation-only:
/// `Tests/AutolinkTests.swift`.
enum Autolink {
    struct Match: Equatable {
        let range: Range<String.Index>
        let reference: AutolinkReference
    }

    private static let changeRequest = try! NSRegularExpression(
        pattern: #"(?<![\w/#])(?:([A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+))?#([0-9]+)\b"#)
    private static let user = try! NSRegularExpression(
        pattern: #"(?<![\w@/.`])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})\b(?![/@])"#)
    private static let sha = try! NSRegularExpression(pattern: #"(?<![\w/.#@-])[0-9a-f]{7,40}(?![\w/-]|\.\w)"#)

    /// The references in `text`, in order, never overlapping. `repo` is the
    /// change request's own, for a bare `#123` and a SHA.
    static func matches(in text: String, repo: String, host: HostKind = .github) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [Match] = []
        for result in changeRequest.matches(in: text, range: whole) {
            guard let range = Range(result.range, in: text),
                  let numberRange = Range(result.range(at: 2), in: text), let number = Int(text[numberRange])
            else { continue }
            let owner = Range(result.range(at: 1), in: text).map { String(text[$0]) }
            found.append(Match(range: range,
                               reference: .changeRequest(ChangeRequestRef(host: host, repo: owner ?? repo, number: number))))
        }
        for result in user.matches(in: text, range: whole) {
            guard let range = Range(result.range, in: text), let login = Range(result.range(at: 1), in: text) else { continue }
            found.append(Match(range: range, reference: .user(String(text[login]))))
        }
        for result in sha.matches(in: text, range: whole) {
            guard let range = Range(result.range, in: text) else { continue }
            let candidate = text[range]
            // A SHA mixes digits and letters; "decade" and "1234567" are words.
            guard candidate.contains(where: \.isNumber), candidate.contains(where: \.isLetter) else { continue }
            found.append(Match(range: range, reference: .commit(repo: repo, sha: String(candidate))))
        }
        var kept: [Match] = []
        for match in found.sorted(by: { $0.range.lowerBound < $1.range.lowerBound })
        where !kept.contains(where: { $0.range.overlaps(match.range) }) {
            kept.append(match)
        }
        return kept
    }

    /// `text` with each resolved reference linked; the rest stays plain.
    static func linked(_ text: String, repo: String, resolver: AutolinkResolver?) -> AttributedString {
        guard let resolver else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches(in: text, repo: repo) {
            guard let url = resolver.url(for: match.reference) else { continue }
            result += AttributedString(text[cursor ..< match.range.lowerBound])
            var link = AttributedString(text[match.range])
            link.link = url
            result += link
            cursor = match.range.upperBound
        }
        result += AttributedString(text[cursor...])
        return result
    }
}
