import CCodeCore
import Foundation

/// A definition or a use of a name, where it is.
public struct Symbol: Hashable, Sendable {
    public enum Role: String, Hashable, Sendable { case definition, reference }
    public let role: Role
    /// `function`, `method`, `class`, `call`, `type`, … as the tags query says.
    public let kind: String
    public let name: String
    public let path: String
    /// 0-based, as a code view counts rows.
    public let line: Int
    /// The name's UTF-16 column.
    public let column: Int

    public init(role: Role, kind: String, name: String, path: String, line: Int, column: Int) {
        self.role = role
        self.kind = kind
        self.name = name
        self.path = path
        self.line = line
        self.column = column
    }
}

/// One repo@head's index while its files come in, a batch at a time (the core parses each
/// batch's tags on up to four threads). Installed into a `SymbolIndexes`, which takes it.
/// One task at a time uses it.
public final class SymbolIndexBuilder: @unchecked Sendable {
    fileprivate var handle: OpaquePointer?

    public init() throws {
        try Core.call { code_core_symbol_builder_new(&handle, $0) }
    }

    deinit { code_core_symbol_builder_free(handle) }

    /// Index a batch of files; the files that did not parse are left out and returned.
    /// Files of an untagged language, or past `SymbolIndexes.fileLimit` bytes, are skipped.
    public func add(_ files: [(path: String, text: String)]) throws -> [(path: String, reason: String)] {
        guard let handle else { return [] }
        var out: UnsafeMutablePointer<CodeCoreFailures>?
        defer { code_core_failures_free(out) }
        try Core.withTexts(files.flatMap { [$0.path, $0.text] }) { texts in
            let pairs = stride(from: 0, to: texts.count, by: 2).map { CodeCoreFile(path: texts[$0], text: texts[$0 + 1]) }
            try pairs.withUnsafeBufferPointer { pairs in
                try Core.call { code_core_symbol_builder_add(handle, pairs.baseAddress, pairs.count, &out, $0) }
            }
        }
        guard let failures = out?.pointee else { return [] }
        return Core.buffer(failures.items, failures.count).map { ($0.path.string, $0.reason.string) }
    }
}

/// The symbol indexes of the last `capacity` repo@heads, least recently used going first:
/// search-based navigation, never a language server. An ambiguous name lists every
/// candidate, ranked same file → imported files → same directory → the rest. Not
/// thread-safe: one owner (an actor) uses it at a time.
public final class SymbolIndexes: @unchecked Sendable {
    public static let capacity = Int(CODE_CORE_SYMBOL_CAPACITY)
    /// A larger file is generated or minified: nobody navigates it.
    public static let fileLimit = Int(CODE_CORE_SYMBOL_FILE_LIMIT)

    private var handle: OpaquePointer?

    public init() {
        do {
            try Core.call { code_core_symbols_new(&handle, $0) }
        } catch {
            NSLog("code-core: the symbol indexes could not start: %@", error.localizedDescription)
        }
    }

    deinit { code_core_symbols_free(handle) }

    /// Keep `builder`'s index as repo@head, replacing what was held for it.
    public func install(_ builder: SymbolIndexBuilder, repo: String, head: String) {
        guard let index = builder.handle else { return }
        builder.handle = nil
        Core.answer("installing \(repo)@\(head)", fallback: ()) {
            try repo.withCore { repo in
                try head.withCore { head in try Core.call { code_core_symbols_install(handle, repo, head, index, $0) } }
            }
        }
    }

    public func isBuilt(repo: String, head: String) -> Bool {
        Core.answer("is \(repo)@\(head) built", fallback: false) {
            var built = false
            try repo.withCore { repo in
                try head.withCore { head in try Core.call { code_core_symbols_is_built(handle, repo, head, &built, $0) } }
            }
            return built
        }
    }

    /// Drops every index.
    public func purge() {
        Core.answer("purging the symbol indexes", fallback: ()) {
            try Core.call { code_core_symbols_purge(handle, $0) }
        }
    }

    /// Where `name` is defined in repo@head, best first: in `path` itself, in a file
    /// `imports` names (or inside an imported directory), in `path`'s directory, then
    /// everywhere else; by path and line within a rank.
    public func definitions(of name: String, repo: String, head: String, from path: String, imports: [String]) -> [Symbol] {
        Core.answer("definitions of \(name)", fallback: []) {
            var out: UnsafeMutablePointer<CodeCoreSymbolList>?
            defer { code_core_symbol_list_free(out) }
            try Core.withTexts([repo, head, name, path] + imports) { texts in
                try Core.call {
                    code_core_symbols_definitions(handle, texts[0], texts[1], texts[2], texts[3],
                                                  texts.baseAddress.map { $0 + 4 }, texts.count - 4, &out, $0)
                }
            }
            return Self.symbols(out)
        }
    }

    /// Every use of `name` in repo@head, by path and line; a spot that also defines it is
    /// left out.
    public func references(of name: String, repo: String, head: String) -> [Symbol] {
        Core.answer("references of \(name)", fallback: []) {
            var out: UnsafeMutablePointer<CodeCoreSymbolList>?
            defer { code_core_symbol_list_free(out) }
            try Core.withTexts([repo, head, name]) { texts in
                try Core.call { code_core_symbols_references(handle, texts[0], texts[1], texts[2], &out, $0) }
            }
            return Self.symbols(out)
        }
    }

    private static func symbols(_ list: UnsafeMutablePointer<CodeCoreSymbolList>?) -> [Symbol] {
        guard let list = list?.pointee else { return [] }
        return Core.buffer(list.symbols, list.count).map {
            Symbol(role: Int32($0.role) == CODE_CORE_TAG_DEFINITION ? .definition : .reference, kind: $0.kind.string,
                   name: $0.name.string, path: $0.path.string, line: Int($0.line), column: Int($0.column))
        }
    }

    // MARK: - Imports

    /// The repo paths a file imports, for ranking definitions: TS and JS relative module
    /// specifiers (and an index barrel's folder), Go import paths' last two components, Rust
    /// `mod` files and `crate::` paths, PHP `use` classes as PSR-4 suffixes. Best effort.
    public static func imports(_ text: String, language: SyntaxLanguage, path: String) -> [String] {
        Core.answer("imports of \(path)", fallback: []) {
            var out: UnsafeMutablePointer<CodeCoreStrings>?
            defer { code_core_strings_free(out) }
            try text.withCore { text in
                try path.withCore { path in try Core.call { code_core_imports(text, language.code, path, &out, $0) } }
            }
            guard let strings = out?.pointee else { return [] }
            return Core.buffer(strings.items, strings.count).map(\.string)
        }
    }

    /// `path` is a file `imports` names, or lies in a directory it names (as path suffixes:
    /// a Go import path or a PHP namespace names the tail of a repo path).
    public static func imported(_ path: String, by imports: [String]) -> Bool {
        Core.answer("is \(path) imported", fallback: false) {
            var imported = false
            try Core.withTexts([path] + imports) { texts in
                try Core.call {
                    code_core_imported(texts[0], texts.baseAddress.map { $0 + 1 }, texts.count - 1, &imported, $0)
                }
            }
            return imported
        }
    }
}
