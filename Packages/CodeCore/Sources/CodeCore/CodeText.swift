import CCodeCore
import Foundation

/// The core's rules for a line of code: the identifier under a column, and which files start
/// folded. Columns, tabs and wrapping are the diff engine's (`Packages/Canvas`), drawn in Rust.
public enum CodeText {
    /// A patch longer than this starts folded.
    public static let collapseLines = Int(CODE_CORE_COLLAPSE_LINES)

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
