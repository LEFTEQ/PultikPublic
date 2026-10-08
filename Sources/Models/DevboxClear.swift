import Foundation

/// Retained command results power both the explanation and the copyable log.
struct DevboxClearReport: Sendable {
    struct Diagnostic: Decodable, Sendable {
        let code: String
        let severity: String?
        let detail: String?
        let fix: String?
    }
    private struct Envelope: Decodable {
        let ok: Bool
        let diagnostics: [Diagnostic]?
        let next: [String]?
    }
    let ok: Bool
    let summary: String
    let diagnostics: [Diagnostic]
    let next: [String]
    let log: String

    static func command(_ arguments: [String], ok: Bool, stdout: String, stderr: String) -> Self {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(stdout.utf8))
        let diagnostics = envelope?.diagnostics ?? []
        let primary = diagnostics.first { $0.severity == "error" } ?? diagnostics.first
        let succeeded = ok && (envelope?.ok ?? false)
        return Self(ok: succeeded,
                    summary: primary?.detail ?? (succeeded ? "Workspace cleared" : "The command failed. See the complete output below."),
                    diagnostics: diagnostics, next: envelope?.next ?? [],
                    log: "$ devbox \(arguments.joined(separator: " "))\n\nstdout:\n\(stdout)\n\nstderr:\n\(stderr)")
    }

    static func failure(_ reason: String, log: String = "") -> Self {
        Self(ok: false, summary: reason, diagnostics: [], next: [], log: log)
    }
}

struct DevboxClearPreview: Sendable {
    let path: String?
    let status: String
    let diff: String
    let commits: String
    let canRemove: Bool
    let complete: Bool
    let explanation: String
    /// Re-read before removing source; changing work never uses an old approval.
    let fingerprint: String
    let log: String
    var additionalSources: [DevboxClearPreview] = []
    /// `git diff HEAD --numstat`: staged and unstaged combined, once per file.
    var numstat = ""
    /// Tracking branch the commit count compares against; nil means every remote.
    var upstream: String?
    /// Status, diffs and commits were read, even when the deletion guard was not.
    var changesRead = false
}

/// What a preview means at a glance. The popover's rows and verdict read only this.
struct DevboxClearSummary: Equatable, Sendable {
    struct File: Equatable, Sendable {
        /// One letter: M A D R C T, `?` untracked, `U` conflicted.
        let kind: Character
        let path: String
        let added: Int?
        let removed: Int?
    }
    struct Commit: Equatable, Sendable {
        let sha: String
        let subject: String
    }
    enum Verdict: Equatable, Sendable {
        case clean, keepsWork, backsUp, discards(files: Int), unread
    }

    let files: [File]
    let commits: [Commit]
    let readable: Bool
    let upstream: String?

    init(_ preview: DevboxClearPreview) {
        var counts: [String: (Int?, Int?)] = [:]
        for line in preview.numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            counts[String(parts[2])] = (Int(parts[0]), Int(parts[1]))
        }
        files = preview.status.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let code = Array(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            let kind: Character = code == ["?", "?"] ? "?"
                : code.contains("U") || code == ["A", "A"] || code == ["D", "D"] ? "U"
                : code[0] != " " ? code[0] : code[1]
            let count = counts[path]
            return File(kind: kind, path: path, added: count?.0, removed: count?.1)
        }
        commits = preview.commits.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return Commit(sha: String(parts[0]), subject: parts.count > 1 ? String(parts[1]) : "")
        }
        readable = preview.changesRead
        upstream = preview.upstream
    }

    var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
    var isClean: Bool { readable && files.isEmpty && commits.isEmpty }
    /// Ordered `M 2 · ? 1` tallies, most common first.
    var kinds: [(kind: Character, count: Int)] {
        Dictionary(grouping: files, by: \.kind).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.kind < $1.kind }
    }

    /// Clearing with Keep never loses source; the verdict says whether anything
    /// local exists at all, and what the chosen worktree action does to it.
    static func verdict(_ sources: [DevboxClearSummary], action: DevboxClearSourceAction) -> Verdict {
        guard sources.allSatisfy(\.readable) else { return .unread }
        let primary = sources.first
        switch action {
        case .discard where primary?.files.isEmpty == false: return .discards(files: primary?.files.count ?? 0)
        case .backup where primary?.files.isEmpty == false: return .backsUp
        default: return sources.allSatisfy(\.isClean) ? .clean : .keepsWork
        }
    }
}

enum DevboxClearSourceAction: String, CaseIterable, Identifiable, Sendable {
    case keep, backup, discard
    var id: Self { self }
    var title: String {
        switch self {
        case .keep: "Keep local source"
        case .backup: "Back up changes and remove worktree"
        case .discard: "Discard changes and remove worktree"
        }
    }
    var short: String {
        switch self {
        case .keep: "Keep"
        case .backup: "Back up & remove"
        case .discard: "Discard & remove"
        }
    }
    var button: String {
        switch self {
        case .keep: "Clear this"
        case .backup: "Back up changes and clear"
        case .discard: "Discard changes and clear"
        }
    }
}
