import CodeCore
import Foundation

/// The Files changed tab as rows (PR workbench WP2): each file's header,
/// then — unless it is folded — its hunks and lines, or why it has none.
/// The rows, their columns, the folds and each line's fragment place are
/// the code core's (`DiffRows`, workbench WP3b); Pultík words the notes.
/// Built once per change set and fold state, off the main thread; the code
/// canvas lays it out per width (`DiffLayout`) and draws only the rows on
/// screen.
struct DiffDocument: Sendable {
    enum Side: Sendable { case old, new }

    struct File: Sendable {
        let changed: ChangedFile
        let lines: [DiffLine]
        let language: SyntaxLanguage?
        let collapsed: Bool
        /// Each line's place in its side's patch-only text (`sideText`):
        /// the highlight source when the mirror names no blob.
        let oldFragment: [Int?]
        let newFragment: [Int?]

        var path: String { changed.path }

        /// The side a line draws from: removed lines are the base's.
        static func side(_ line: DiffLine) -> Side { line.kind == .removed ? .old : .new }

        /// Where `lines[index]` sits in `side`'s highlight source: its line
        /// in the blob when there is one, else in the patch-only text.
        func sourceLine(_ index: Int, side: Side) -> Int? {
            let line = lines[index]
            switch side {
            case .new: return changed.newBlob != nil ? line.new.map { $0 - 1 } : newFragment[index]
            case .old: return changed.oldBlob != nil ? line.old.map { $0 - 1 } : oldFragment[index]
            }
        }

        /// One side's text as the patch alone holds it — context and that
        /// side's lines, in order.
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

    enum Row: Equatable, Sendable {
        case header(file: Int)
        case line(file: Int, index: Int)
        case note(file: Int, text: String)
        /// The space between two files.
        case gap
    }

    let files: [File]
    let rows: [Row]
    /// Each row's drawn width in columns — the wrap model's input.
    let columns: [Int]
    /// The gutter's figure width, shared by every file so the code column lines up.
    let digits: Int
    /// What a layout reads: each row's kind and width.
    let shape: DiffRows.Shape

    static let tabWidth = CodeText.tabWidth

    init(_ changes: ChangeSet?, collapsed toggled: Set<String> = []) {
        let changed = changes?.files ?? []
        let core = DiffRows(changed.map { DiffRows.Input(path: $0.path, patch: $0.patch, trimmed: $0.trimmed) },
                            truncated: changes?.truncated == true, toggled: toggled)
        files = zip(changed, core.files).map { changed, file in
            File(changed: changed, lines: file.lines, language: file.language, collapsed: file.collapsed,
                 oldFragment: file.oldFragment, newFragment: file.newFragment)
        }
        rows = core.rows.map { row in
            switch row {
            case let .header(file): .header(file: file)
            case let .line(file, index): .line(file: file, index: index)
            case let .note(file, note): .note(file: file, text: Self.words(note))
            case .gap: .gap
            }
        }
        columns = core.columns
        digits = core.digits
        shape = core.shape
    }

    /// Why a file shows a note, worded.
    private static func words(_ note: DiffRows.Note) -> String {
        switch note {
        case .pastBudget: "Past the patch budget — ⌘↵ opens it on the host"
        case .noDiff: "No diff — binary, renamed or empty"
        case let .folded(lines, generated):
            "\(lines) lines, \(generated ? "generated" : "long") — click the header or ↵ to show"
        case .cutHere: "Diff cut here — ⌘↵ opens the rest on the host"
        case let .hostListsFirst(files): "The host lists the first \(files) files — ⌘↵ opens the rest"
        }
    }

    /// A lockfile or generated file, or one past `collapseLines`, starts folded.
    static let collapseLines = CodeText.collapseLines

    static func collapsedByDefault(_ file: ChangedFile, lines: Int) -> Bool {
        CodeText.collapsedByDefault(path: file.path, lines: lines)
    }

    /// The first row of each file, by file index — what ⇥ and the tree jump to.
    var headerRows: [Int] {
        rows.indices.filter { if case .header = rows[$0] { true } else { false } }
    }

    /// `text`'s width in columns: a tab runs to the next multiple of
    /// `tabWidth`, East Asian wide chars and emoji take two, combining marks
    /// none (the code core's rule).
    static func columns(_ text: String) -> Int {
        CodeText.columns(text)
    }

    /// `text` with its tabs expanded, and each original UTF-16 offset's
    /// place in it (one past the end included) — so token runs, selection
    /// and hit-testing map between the two.
    static func expandTabs(_ text: String) -> (text: String, map: [Int]) {
        CodeText.expandTabs(text)
    }

    /// Where each visual row after the first starts, in UTF-16 units, when
    /// a line's drawn text (tabs expanded) wraps at `columns`: the drawing
    /// half of the layout's rule, so a line fills exactly the rows it has.
    static func rowStarts(_ display: String, columns: Int) -> [Int] {
        CodeText.rowStarts(display, columns: columns)
    }
}

/// The document laid out at one width (D9): each row's height — a wrapped
/// line is several visual rows — and the running offsets a binary search
/// finds the rows on screen with. The code core's (workbench WP3b).
typealias DiffLayout = CodeCore.DiffLayout

extension DiffLayout {
    init(_ document: DiffDocument, width: CGFloat, wraps: Bool, metrics: Metrics) {
        self.init(document.shape, width: width, wraps: wraps, metrics: metrics)
    }
}
