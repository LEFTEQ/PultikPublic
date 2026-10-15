import CCodeCore
import Foundation

/// The core's rules for a line of code on screen: its width in columns (a tab runs to the
/// next stop, East Asian wide chars and emoji take two, combining marks none), its tabs
/// expanded, where it wraps, the identifier under a column, and which files start folded.
public enum CodeText {
    /// A tab runs to the next multiple of this many columns.
    public static let tabWidth = Int(CODE_CORE_TAB_WIDTH)
    /// A patch longer than this starts folded.
    public static let collapseLines = Int(CODE_CORE_COLLAPSE_LINES)

    /// `text`'s width in columns.
    public static func columns(_ text: String) -> Int {
        Core.answer("columns", fallback: text.utf16.count) {
            var columns: UInt32 = 0
            try text.withCore { text in try Core.call { code_core_columns(text, &columns, $0) } }
            return Int(columns)
        }
    }

    /// `text` with its tabs expanded, and each original UTF-16 offset's place in it (one past
    /// the end included), so runs, selection and hit-testing map between the two.
    public static func expandTabs(_ text: String) -> (text: String, map: [Int]) {
        // Without a tab the core answers the text itself and the identity map.
        guard text.utf16.contains(0x09) else { return (text, Array(0 ... text.utf16.count)) }
        return Core.answer("expanding tabs", fallback: (text, Array(0 ... text.utf16.count))) {
            var out: UnsafeMutablePointer<CodeCoreExpanded>?
            defer { code_core_expanded_free(out) }
            try text.withCore { text in try Core.call { code_core_expand_tabs(text, &out, $0) } }
            guard let expanded = out?.pointee else { return (text, Array(0 ... text.utf16.count)) }
            return (expanded.text.string, Core.buffer(expanded.map, expanded.map_count).map(Int.init))
        }
    }

    /// Where each visual row after the first starts, in UTF-16 units, when the drawn `text`
    /// (tabs expanded) wraps at `columns`: a char sits on the row its first column falls in,
    /// so a line never draws more rows than its columns lay out.
    public static func rowStarts(_ text: String, columns: Int) -> [Int] {
        Core.answer("wrapping a line", fallback: []) {
            var out: UnsafeMutablePointer<CodeCoreNumbers>?
            defer { code_core_numbers_free(out) }
            try text.withCore { text in
                try Core.call { code_core_row_starts(text, UInt32(clamping: max(columns, 1)), &out, $0) }
            }
            guard let numbers = out?.pointee else { return [] }
            return Core.buffer(numbers.values, numbers.count).map(Int.init)
        }
    }

    /// The identifier under UTF-16 `column` of `line` (letters, digits, `_` and `$`, not
    /// starting with a digit); nil off one.
    public static func wordAt(_ line: String, column: Int) -> String? {
        let units = Array(line.utf16)
        let range: Range<Int>? = Core.answer("the word at \(column)", fallback: nil) {
            var found = false
            var word = CodeCoreRange(start: 0, end: 0)
            try units.withUnsafeBufferPointer { units in
                try Core.call { code_core_word_at(units.baseAddress, units.count, Int64(column), &found, &word, $0) }
            }
            return found ? Int(word.start) ..< Int(word.end) : nil
        }
        return range.map { String(decoding: units[$0], as: UTF16.self) }
    }

    /// A lockfile or a generated file: nobody reads its diff line by line.
    public static func isGenerated(_ path: String) -> Bool {
        Core.answer("is \(path) generated", fallback: false) {
            var generated = false
            try path.withCore { path in try Core.call { code_core_is_generated(path, &generated, $0) } }
            return generated
        }
    }

    /// A generated file, or a patch past `collapseLines`, starts folded.
    public static func collapsedByDefault(path: String, lines: Int) -> Bool {
        Core.answer("is \(path) folded", fallback: false) {
            var collapsed = false
            try path.withCore { path in
                try Core.call { code_core_collapsed_by_default(path, max(lines, 0), &collapsed, $0) }
            }
            return collapsed
        }
    }
}
