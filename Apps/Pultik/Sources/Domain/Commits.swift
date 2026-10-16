import Foundation

/// One commit of a change request, read from the mirror (PR workbench S9):
/// the Commits tab lists `base..head` oldest first, and ↵ scopes Files
/// changed to it (`GitMirror.commitChangeSet`). No host API: the mirror
/// already holds every commit the diff walked.
/// Foundation-only: the contract harness builds it.
struct ChangeCommit: Codable, Sendable, Equatable, Identifiable {
    let sha: String
    /// The first is the one its change set diffs against; none for a root.
    let parents: [String]
    let author: String
    /// When it was authored, the date a host shows beside a commit.
    let date: Date
    let subject: String
    /// The message after the subject, trimmed; empty when there is none.
    let body: String
    /// Totals against the first parent; a binary file counts as a file
    /// without lines.
    let additions: Int
    let deletions: Int
    let files: Int

    var id: String { sha }
}

/// One match of a code search at a change request's head (PR workbench D3,
/// S13), as `git grep` found it in the mirror: one hit per match, so a
/// line matching twice is two hits.
struct GrepHit: Codable, Sendable, Hashable, Identifiable {
    let path: String
    /// 1-based, as an editor counts.
    let line: Int
    /// 0-based UTF-16 offset of the match in `text`.
    let column: Int
    /// The match's UTF-16 length.
    let length: Int
    /// The whole line, without its newline.
    let text: String

    var id: String { "\(path):\(line):\(column)" }
}

/// How a code search reads its query (PR workbench S13): match case, whole
/// word and regex, the three toggles of an editor's search field.
struct SearchOptions: Codable, Sendable, Hashable {
    var caseSensitive = false
    var wholeWord = false
    /// Perl-compatible, the dialect an editor's search field speaks.
    var regex = false
}
