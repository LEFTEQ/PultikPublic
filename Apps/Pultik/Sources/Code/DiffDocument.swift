import CodeCore
import Foundation

/// The Files changed tab's change set as Swift reads it (PR workbench WP2):
/// each file's drawn lines, language and fold, the code core's (`DiffRows`,
/// workbench WP3b). The code canvas's `DiffEngine` builds its own rows from
/// the same files, `truncated` and `toggled`, and words the notes; Swift
/// keeps this for the tree, the marks, the comment anchors and the
/// highlighting requests. Built once per change set and fold state, off the
/// main thread.
struct DiffDocument: Sendable {
    enum Side: Sendable { case old, new }

    struct File: Sendable {
        let changed: ChangedFile
        let lines: [DiffLine]
        let language: SyntaxLanguage?
        let collapsed: Bool

        var path: String { changed.path }

        /// One side's text as the patch alone holds it — context and that
        /// side's lines, in order: the highlight source when the mirror
        /// names no blob.
        func sideText(_ side: Side) -> String {
            lines.filter { line in
                switch line.kind {
                case .context: true
                case .added: side == .new
                case .removed: side == .old
                case .hunk, .note: false
                }
            }.map(\.text).joined(separator: "\n")
        }
    }

    let files: [File]
    /// The host stopped listing before the last file.
    let truncated: Bool
    /// The paths whose fold the reader flipped from their default.
    let toggled: Set<String>

    init(_ changes: ChangeSet?, collapsed toggled: Set<String> = []) {
        let changed = changes?.files ?? []
        truncated = changes?.truncated == true
        self.toggled = toggled
        let core = DiffRows(changed.map { DiffRows.Input(path: $0.path, patch: $0.patch, trimmed: $0.trimmed) },
                            truncated: truncated, toggled: toggled)
        files = zip(changed, core.files).map { changed, file in
            File(changed: changed, lines: file.lines, language: file.language, collapsed: file.collapsed)
        }
    }

    /// A lockfile or a generated file, or a long patch, starts folded (the code core's rule).
    static func collapsedByDefault(_ file: ChangedFile, lines: Int) -> Bool {
        CodeText.collapsedByDefault(path: file.path, lines: lines)
    }
}
