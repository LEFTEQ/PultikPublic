import CCodeCore
import Foundation

/// One diff line as drawn: its 1-based gutter numbers and its kind. The text is the line's
/// own, without the `+`/`-`/` ` marker.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case hunk, context, added, removed, note }

    public let kind: Kind
    public let old: Int?
    public let new: Int?
    public let text: String

    public init(kind: Kind, old: Int?, new: Int?, text: String) {
        self.kind = kind
        self.old = old
        self.new = new
        self.text = text
    }

    /// A unified patch → drawn lines. A `@@ -a,b +c,d @@` header resets both counters;
    /// `\ No newline at end of file` is a note.
    public static func parse(_ patch: String) -> [DiffLine] {
        Core.answer("parsing a patch", fallback: []) {
            var out: UnsafeMutablePointer<CodeCoreDiffLines>?
            defer { code_core_diff_lines_free(out) }
            try patch.withCore { patch in try Core.call { code_core_diff_parse(patch, &out, $0) } }
            guard let parsed = out?.pointee else { return [] }
            return lines(Core.buffer(parsed.lines, parsed.count))
        }
    }

    static func lines(_ lines: UnsafeBufferPointer<CodeCoreDiffLine>) -> [DiffLine] {
        lines.map {
            DiffLine(kind: kind($0.kind), old: Core.number($0.old_number), new: Core.number($0.new_number),
                     text: $0.text.string)
        }
    }

    private static func kind(_ code: UInt8) -> Kind {
        switch Int32(code) {
        case CODE_CORE_LINE_HUNK: .hunk
        case CODE_CORE_LINE_ADDED: .added
        case CODE_CORE_LINE_REMOVED: .removed
        case CODE_CORE_LINE_NOTE: .note
        default: .context
        }
    }
}

/// A change set as rows (the core's `DiffDocument`): each file's header, then (unless it is
/// folded) its lines, or why it has none. The notes are data; the app words them.
public struct DiffRows: Sendable {
    /// One file of the change set, as far as its rows need it.
    public struct Input: Sendable {
        public let path: String
        /// Nil for a binary file, one the source would not diff, or one past the budget.
        public let patch: String?
        /// The patch was cut at its source's line limit or dropped past its byte budget.
        public let trimmed: Bool

        public init(path: String, patch: String?, trimmed: Bool) {
            self.path = path
            self.patch = patch
            self.trimmed = trimmed
        }
    }

    public struct File: Sendable {
        public let lines: [DiffLine]
        public let language: SyntaxLanguage?
        public let collapsed: Bool
        /// Each line's place in its side's patch-only text; nil where it is not that side's.
        public let oldFragment: [Int?]
        public let newFragment: [Int?]
    }

    /// Why a file shows a note row.
    public enum Note: Equatable, Sendable {
        case pastBudget, noDiff, folded(lines: Int, generated: Bool), cutHere, hostListsFirst(files: Int)
    }

    public enum Row: Equatable, Sendable {
        case header(file: Int)
        case line(file: Int, index: Int)
        case note(file: Int, Note)
        /// The space between two files.
        case gap
    }

    /// What a layout reads: each row's kind and width.
    public struct Shape: Sendable {
        let kinds: [UInt8]
        let columns: [UInt32]
    }

    public let files: [File]
    public let rows: [Row]
    /// Each row's drawn width in columns: the wrap model's input.
    public let columns: [Int]
    /// The gutter's figure width, shared by every file so the code column lines up.
    public let digits: Int
    public let shape: Shape

    /// `inputs` in drawn order; `truncated` when the host stopped listing before the last
    /// file; `toggled` the paths whose fold the reader flipped.
    public init(_ inputs: [Input], truncated: Bool, toggled: Set<String>) {
        var out: UnsafeMutablePointer<CodeCoreDiffDocument>?
        defer { code_core_diff_document_free(out) }
        let toggled = Array(toggled)
        do {
            try Core.withTexts(inputs.flatMap { [$0.path, $0.patch ?? ""] } + toggled) { texts in
                let files = inputs.indices.map { i in
                    CodeCoreChangedFile(path: texts[2 * i], patch: texts[2 * i + 1], has_patch: inputs[i].patch != nil,
                                        trimmed: inputs[i].trimmed)
                }
                try files.withUnsafeBufferPointer { files in
                    try Core.call {
                        code_core_diff_document(files.baseAddress, files.count, truncated,
                                                texts.baseAddress.map { $0 + 2 * inputs.count }, toggled.count, &out, $0)
                    }
                }
            }
        } catch {
            NSLog("code-core: a change set's rows: %@", error.localizedDescription)
        }
        guard let document = out?.pointee else {
            self.init(files: [], rows: [], columns: [], digits: 3)
            return
        }
        let files = Core.buffer(document.files, document.file_count).map { file in
            File(lines: DiffLine.lines(Core.buffer(file.lines, file.line_count)),
                 language: SyntaxLanguage(code: file.language), collapsed: file.collapsed,
                 oldFragment: Core.buffer(file.old_fragment, file.line_count).map(Core.number),
                 newFragment: Core.buffer(file.new_fragment, file.line_count).map(Core.number))
        }
        let rows = Core.buffer(document.rows, document.row_count).map(Self.row)
        let columns = Core.buffer(document.columns, document.row_count).map(Int.init)
        self.init(files: files, rows: rows, columns: columns, digits: Int(document.digits))
    }

    private init(files: [File], rows: [Row], columns: [Int], digits: Int) {
        self.files = files
        self.rows = rows
        self.columns = columns
        self.digits = digits
        shape = Shape(kinds: rows.map(Self.kind), columns: columns.map { UInt32(clamping: $0) })
    }

    private static func row(_ row: CodeCoreDocRow) -> Row {
        let file = Int(row.file)
        switch Int32(row.kind) {
        case CODE_CORE_ROW_HEADER: return .header(file: file)
        case CODE_CORE_ROW_LINE: return .line(file: file, index: Int(row.index))
        case CODE_CORE_ROW_NOTE:
            let note: Note = switch Int32(row.note) {
            case CODE_CORE_NOTE_PAST_BUDGET: .pastBudget
            case CODE_CORE_NOTE_FOLDED: .folded(lines: Int(row.count), generated: row.generated)
            case CODE_CORE_NOTE_CUT_HERE: .cutHere
            case CODE_CORE_NOTE_HOST_LISTS_FIRST: .hostListsFirst(files: Int(row.count))
            default: .noDiff
            }
            return .note(file: file, note)
        default: return .gap
        }
    }

    private static func kind(_ row: Row) -> UInt8 {
        let kind: Int32 = switch row {
        case .header: CODE_CORE_ROW_HEADER
        case .line: CODE_CORE_ROW_LINE
        case .note: CODE_CORE_ROW_NOTE
        case .gap: CODE_CORE_ROW_GAP
        }
        return UInt8(kind)
    }
}

/// Rows laid out at one width: each row's height (a wrapped line is several visual rows)
/// and the running offsets a binary search finds the rows on screen with. The heights are
/// the core's; finding rows is a search over them, here, because it runs every frame.
public struct DiffLayout: Sendable {
    /// Row heights and the code column's place, in points; a fresh value holds the core's
    /// defaults.
    public struct Metrics: Equatable, Sendable {
        public var lineHeight: CGFloat
        public var headerHeight: CGFloat
        public var gapHeight: CGFloat
        public var noteHeight: CGFloat
        public var advance: CGFloat
        /// The code column's left edge: the gutter and the ± marker.
        public var codeX: CGFloat

        public init() {
            let core = Self.defaults
            lineHeight = core.line_height
            headerHeight = core.header_height
            gapHeight = core.gap_height
            noteHeight = core.note_height
            advance = core.advance
            codeX = core.code_x
        }

        private static let defaults: CodeCoreDiffMetrics = Core.answer(
            "the default metrics",
            fallback: CodeCoreDiffMetrics(line_height: 18, header_height: 30, gap_height: 12, note_height: 24,
                                          advance: 7.2, code_x: 0)
        ) {
            var metrics = CodeCoreDiffMetrics()
            try Core.call { code_core_diff_metrics_default(&metrics, $0) }
            return metrics
        }

        var core: CodeCoreDiffMetrics {
            CodeCoreDiffMetrics(line_height: lineHeight, header_height: headerHeight, gap_height: gapHeight,
                                note_height: noteHeight, advance: advance, code_x: codeX)
        }
    }

    public let metrics: Metrics
    /// Columns per visual row; nil = no wrapping.
    public let wrapColumns: Int?
    /// Visual rows per row (1 for headers, notes and gaps).
    public let visualRows: [Int]
    /// `offsets[i]` is row i's top; the last is the height.
    public let offsets: [CGFloat]

    public init(_ shape: DiffRows.Shape, width: CGFloat, wraps: Bool, metrics: Metrics) {
        self.metrics = metrics
        var out: UnsafeMutablePointer<CodeCoreDiffLayout>?
        defer { code_core_diff_layout_free(out) }
        do {
            try shape.kinds.withUnsafeBufferPointer { kinds in
                try shape.columns.withUnsafeBufferPointer { columns in
                    try Core.call {
                        code_core_diff_layout(kinds.baseAddress, columns.baseAddress, kinds.count, Double(width), wraps,
                                              metrics.core, &out, $0)
                    }
                }
            }
        } catch {
            NSLog("code-core: laying rows out: %@", error.localizedDescription)
        }
        guard let layout = out?.pointee else {
            wrapColumns = nil
            visualRows = Array(repeating: 1, count: shape.kinds.count)
            offsets = Array(repeating: 0, count: shape.kinds.count + 1)
            return
        }
        wrapColumns = layout.wrap_columns > 0 ? Int(layout.wrap_columns) : nil
        visualRows = Core.buffer(layout.visual_rows, layout.row_count).map(Int.init)
        offsets = Core.buffer(layout.offsets, layout.row_count + 1).map { CGFloat($0) }
    }

    public var height: CGFloat { offsets.last ?? 0 }

    public func frame(_ row: Int) -> (y: CGFloat, height: CGFloat) {
        (offsets[row], offsets[row + 1] - offsets[row])
    }

    /// The row whose span holds `y` (clamped to the document).
    public func row(at y: CGFloat) -> Int {
        let count = offsets.count - 1
        guard count > 0 else { return 0 }
        var low = 0
        var high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The rows intersecting `minY ..< maxY`.
    public func rows(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        let count = offsets.count - 1
        guard count > 0 else { return 0 ..< 0 }
        return row(at: max(0, minY)) ..< min(count, row(at: maxY) + 1)
    }
}

/// A whole diff: unified lines, their hunks, each line's changed words and the side-by-side
/// rows: what a change opens as, inline (`lines`) or side by side (`split`).
public struct TextDiff: Sendable {
    public struct Hunk: Equatable, Sendable {
        /// The header's index in `lines`, and the hunk's lines after it.
        public let header: Int
        public let oldStart: Int
        public let oldLines: Int
        public let newStart: Int
        public let newLines: Int
        /// What follows the header's second `@@` (the enclosing function, as git guesses it).
        public let section: String
        public let lines: Range<Int>
    }

    /// A hunk header or note across both sides, or a line on each side (an index into
    /// `lines`; nil is a filler).
    public enum SplitRow: Equatable, Sendable {
        case hunk(Int), note(Int), pair(old: Int?, new: Int?)
    }

    public let lines: [DiffLine]
    public let hunks: [Hunk]
    /// Each line's changed words, UTF-16 ranges of its text; empty where it pairs with none
    /// or reads as rewritten.
    public let words: [[Range<Int>]]
    public let split: [SplitRow]

    /// `old` → `new` with `context` lines around each change.
    public init(old: String, new: String, context: Int = 3) throws {
        var out: UnsafeMutablePointer<CodeCoreTextDiff>?
        defer { code_core_text_diff_free(out) }
        try old.withCore { old in
            try new.withCore { new in
                try Core.call { code_core_text_diff(old, new, UInt32(clamping: max(context, 0)), &out, $0) }
            }
        }
        self.init(out?.pointee)
    }

    /// A unified patch (a file's part of `git diff`, from its first `@@`).
    public init(patch: String) throws {
        var out: UnsafeMutablePointer<CodeCoreTextDiff>?
        defer { code_core_text_diff_free(out) }
        try patch.withCore { patch in try Core.call { code_core_patch_diff(patch, &out, $0) } }
        self.init(out?.pointee)
    }

    private init(_ diff: CodeCoreTextDiff?) {
        guard let diff else {
            (lines, hunks, words, split) = ([], [], [], [])
            return
        }
        lines = DiffLine.lines(Core.buffer(diff.lines, diff.line_count))
        hunks = Core.buffer(diff.hunks, diff.hunk_count).map {
            Hunk(header: Int($0.header), oldStart: Int($0.old_start), oldLines: Int($0.old_lines),
                 newStart: Int($0.new_start), newLines: Int($0.new_lines), section: $0.section.string,
                 lines: Int($0.first_line) ..< Int($0.end_line))
        }
        let starts = Core.buffer(diff.word_starts, diff.line_count + 1)
        let all = Core.buffer(diff.words, Int(starts.last ?? 0))
        words = (0 ..< diff.line_count).map { i in
            all[Int(starts[i]) ..< Int(starts[i + 1])].map { Int($0.start) ..< Int($0.end) }
        }
        split = Core.buffer(diff.split, diff.split_count).map {
            switch Int32($0.kind) {
            case CODE_CORE_SPLIT_HUNK: .hunk(Int($0.line))
            case CODE_CORE_SPLIT_NOTE: .note(Int($0.line))
            default: .pair(old: Core.number($0.old_line), new: Core.number($0.new_line))
            }
        }
    }
}
