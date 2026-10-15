import CCodeCore
import Foundation

/// A language the core highlights: one tree-sitter grammar and its vendored queries
/// (`Apps/Pultik/Resources/Queries/<rawValue>/`, compiled into the core). Everything else
/// draws as plain text.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case go, typescript, tsx, javascript, html, json, yaml, markdown, rust, bash, php

    /// By the file's extension (or name); nil = plain text.
    public init?(path: String) {
        let code = Core.answer("the language of \(path)", fallback: Core.none) {
            var code = Core.none
            try path.withCore { path in try Core.call { code_core_language(path, &code, $0) } }
            return code
        }
        self.init(code: code)
    }

    /// The tags query names definitions and references (the symbol index); the data and
    /// prose grammars ship none.
    public var hasTags: Bool { Self.tagged[self] ?? false }

    private static let tagged: [SyntaxLanguage: Bool] = Dictionary(uniqueKeysWithValues: allCases.map { language in
        (language, Core.answer("\(language.rawValue)'s tags", fallback: false) {
            var tagged = false
            try Core.call { code_core_language_has_tags(language.code, &tagged, $0) }
            return tagged
        })
    })

    init?(code: UInt32) {
        let codes: [(Int32, SyntaxLanguage)] = [
            (CODE_CORE_LANGUAGE_GO, .go), (CODE_CORE_LANGUAGE_TYPESCRIPT, .typescript), (CODE_CORE_LANGUAGE_TSX, .tsx),
            (CODE_CORE_LANGUAGE_JAVASCRIPT, .javascript), (CODE_CORE_LANGUAGE_HTML, .html),
            (CODE_CORE_LANGUAGE_JSON, .json), (CODE_CORE_LANGUAGE_YAML, .yaml), (CODE_CORE_LANGUAGE_MARKDOWN, .markdown),
            (CODE_CORE_LANGUAGE_RUST, .rust), (CODE_CORE_LANGUAGE_BASH, .bash), (CODE_CORE_LANGUAGE_PHP, .php),
        ]
        guard let language = codes.first(where: { UInt32($0.0) == code })?.1 else { return nil }
        self = language
    }

    var code: UInt32 {
        let code: Int32 = switch self {
        case .go: CODE_CORE_LANGUAGE_GO
        case .typescript: CODE_CORE_LANGUAGE_TYPESCRIPT
        case .tsx: CODE_CORE_LANGUAGE_TSX
        case .javascript: CODE_CORE_LANGUAGE_JAVASCRIPT
        case .html: CODE_CORE_LANGUAGE_HTML
        case .json: CODE_CORE_LANGUAGE_JSON
        case .yaml: CODE_CORE_LANGUAGE_YAML
        case .markdown: CODE_CORE_LANGUAGE_MARKDOWN
        case .rust: CODE_CORE_LANGUAGE_RUST
        case .bash: CODE_CORE_LANGUAGE_BASH
        case .php: CODE_CORE_LANGUAGE_PHP
        }
        return UInt32(code)
    }
}

/// What a highlight run means on screen: a code theme's syntax role, in the core's
/// `theme::SyntaxRole` order after `plain` (the raw value is the core's run kind).
public enum TokenKind: UInt8, CaseIterable, Sendable {
    case plain, keyword, string, escape, function, type, variable, builtin, parameter, property, number, constant,
         comment, `operator`, punctuation, tag, attribute, module, heading, literal, emphasis, strong, link
}

/// A run of one kind inside a line, in UTF-16 units from the line's start.
public struct TokenRun: Equatable, Sendable {
    public let start: Int32
    public let length: Int32
    public let kind: TokenKind

    public init(start: Int32, length: Int32, kind: TokenKind) {
        self.start = start
        self.length = length
        self.kind = kind
    }
}

/// A text's runs by line (0-based); a line with none is plain. Flat, as the core answers:
/// one run list and each line's first run.
public struct LineTokens: Sendable {
    private let all: [TokenRun]
    /// Line `i`'s runs are `all[starts[i] ..< starts[i + 1]]`.
    private let starts: [Int32]

    public init(runs: [TokenRun], lineStarts: [Int32]) {
        all = runs
        starts = lineStarts
    }

    public var lineCount: Int { max(starts.count - 1, 0) }

    public func runs(line index: Int) -> ArraySlice<TokenRun> {
        guard index >= 0, index + 1 < starts.count else { return [] }
        return all[Int(starts[index]) ..< Int(starts[index + 1])]
    }

    /// How many lines and runs it holds: a cache's cost.
    public var weight: Int { lineCount + all.count }
}

/// Highlighting and tags in one parse per text (the core's one-shot half). For one node the
/// deepest pattern paints, then the later one (`specificity`); Markdown's inline grammar
/// fills what the block grammar left plain. Thread-safe: callers run it off the main thread.
public enum SyntaxEngine {
    /// A definition or reference the tags query names, by its identifier.
    public struct Tag: Equatable, Sendable {
        public enum Role: String, Sendable { case definition, reference }
        public let role: Role
        /// `function`, `class`, `method`, `call`, `type`, … as the query says.
        public let kind: String
        public let name: String
        /// 0-based line, and the name's UTF-16 column on it.
        public let line: Int
        public let column: Int
    }

    public static func highlight(_ text: String, language: SyntaxLanguage) throws -> LineTokens {
        var out: UnsafeMutablePointer<CodeCoreTokens>?
        defer { code_core_tokens_free(out) }
        try text.withCore { text in try Core.call { code_core_highlight(text, language.code, &out, $0) } }
        guard let tokens = out?.pointee else { return LineTokens(runs: [], lineStarts: []) }
        let runs = Core.buffer(tokens.runs, tokens.run_count).map {
            TokenRun(start: Int32($0.start), length: Int32($0.length), kind: TokenKind(rawValue: $0.kind) ?? .plain)
        }
        return LineTokens(runs: runs, lineStarts: Core.buffer(tokens.line_starts, tokens.line_start_count).map(Int32.init))
    }

    public static func tags(_ text: String, language: SyntaxLanguage) throws -> [Tag] {
        var out: UnsafeMutablePointer<CodeCoreTags>?
        defer { code_core_tags_free(out) }
        try text.withCore { text in try Core.call { code_core_tags(text, language.code, &out, $0) } }
        guard let tags = out?.pointee else { return [] }
        return Core.buffer(tags.tags, tags.count).map {
            Tag(role: Int32($0.role) == CODE_CORE_TAG_DEFINITION ? .definition : .reference, kind: $0.kind.string,
                name: $0.name.string, line: Int($0.line), column: Int($0.column))
        }
    }

    /// Each top-level pattern's depth of node structure in a query source, in pattern order:
    /// `(identifier)` is 1, `(call function: (identifier))` 2, `"func"` 0.
    public static func specificity(_ source: String) -> [Int] {
        Core.answer("specificity", fallback: []) {
            var out: UnsafeMutablePointer<CodeCoreNumbers>?
            defer { code_core_numbers_free(out) }
            try source.withCore { source in try Core.call { code_core_specificity(source, &out, $0) } }
            guard let numbers = out?.pointee else { return [] }
            return Core.buffer(numbers.values, numbers.count).map(Int.init)
        }
    }
}
