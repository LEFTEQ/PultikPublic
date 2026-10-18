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

/// A change set's files as the core reads them (its `DiffDocument`): each file's drawn lines,
/// its language and whether it starts folded. The rows, their layout and the notes' words are
/// the diff engine's (`crates/canvas-ffi`, Pultík's `Packages/Canvas`), not Swift's.
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
    }

    public let files: [File]

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
            files = []
            return
        }
        files = Core.buffer(document.files, document.file_count).map { file in
            File(lines: DiffLine.lines(Core.buffer(file.lines, file.line_count)),
                 language: SyntaxLanguage(code: file.language), collapsed: file.collapsed)
        }
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
