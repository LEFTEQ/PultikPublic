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
    var button: String {
        switch self {
        case .keep: "Clear this"
        case .backup: "Back up changes and clear"
        case .discard: "Discard changes and clear"
        }
    }
}
