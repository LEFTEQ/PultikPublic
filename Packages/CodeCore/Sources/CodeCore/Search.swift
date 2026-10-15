import CCodeCore
import Foundation

/// How a search reads its query: an editor's three toggles. A regex is the core's dialect
/// (Rust `regex`): a pattern it cannot read finds only git's own first match.
public struct SearchToggles: Hashable, Sendable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }

    var core: CodeCoreSearchOptions {
        CodeCoreSearchOptions(case_sensitive: caseSensitive, whole_word: wholeWord, regex: regex)
    }
}

/// Every match of a search in one line, found the way git walks a line: leftmost first, the
/// next from the previous match's end; under whole word a word is ASCII letters, digits and
/// `_`. Immutable, so any thread may use it.
public final class LineMatcher: @unchecked Sendable {
    private var handle: OpaquePointer?

    public init(query: String, toggles: SearchToggles) throws {
        try query.withCore { query in try Core.call { code_core_matcher_new(query, toggles.core, &handle, $0) } }
    }

    deinit { code_core_matcher_free(handle) }

    /// The UTF-16 ranges of every match in `line`; when the matcher finds none, git's own
    /// first match at UTF-16 `firstColumn`.
    public func ranges(in line: String, firstColumn: Int) -> [Range<Int>] {
        Core.answer("matching a line", fallback: []) {
            var out: UnsafeMutablePointer<CodeCoreRanges>?
            defer { code_core_ranges_free(out) }
            try line.withCore { line in
                try Core.call { code_core_matcher_ranges(handle, line, max(firstColumn, 0), &out, $0) }
            }
            guard let ranges = out?.pointee else { return [] }
            return Core.buffer(ranges.ranges, ranges.count).map { Int($0.start) ..< Int($0.end) }
        }
    }
}

/// `git grep -z -n --column` records turning into hits as git printed them, one hit per
/// match, at most `limit`. Running git is the caller's; one thread at a time feeds it.
public final class GrepRecords: @unchecked Sendable {
    /// One match: a line matching twice is two hits.
    public struct Hit: Hashable, Sendable {
        public let path: String
        /// 1-based, as an editor counts.
        public let line: Int
        /// The match's UTF-16 offset in `text`, and its UTF-16 length.
        public let column: Int
        public let length: Int
        /// The whole line, without its line ending.
        public let text: String
    }

    private var handle: OpaquePointer?

    public init(head: String, limit: Int, query: String, toggles: SearchToggles) throws {
        try head.withCore { head in
            try query.withCore { query in
                try Core.call { code_core_grep_new(head, max(limit, 0), query, toggles.core, &handle, $0) }
            }
        }
    }

    deinit { code_core_grep_free(handle) }

    /// Take one record, `<head>:<path>\0<line>\0<byte column>\0<text>`. `more` is false once
    /// the limit is in (stop git); `readable` is false for a record of another shape.
    public func add(_ record: Data) throws -> (more: Bool, readable: Bool) {
        var more = false
        var readable = false
        try record.withUnsafeBytes { bytes in
            let record = CodeCoreStr(ptr: bytes.bindMemory(to: UInt8.self).baseAddress, len: bytes.count)
            try Core.call { code_core_grep_add(handle, record, &more, &readable, $0) }
        }
        return (more, readable)
    }

    /// The hits so far, in git's order.
    public func hits() throws -> [Hit] {
        var out: UnsafeMutablePointer<CodeCoreHits>?
        defer { code_core_hits_free(out) }
        try Core.call { code_core_grep_hits(handle, &out, $0) }
        guard let hits = out?.pointee else { return [] }
        return Core.buffer(hits.hits, hits.count).map {
            Hit(path: $0.path.string, line: Int($0.line), column: Int($0.column), length: Int($0.length),
                text: $0.text.string)
        }
    }
}
