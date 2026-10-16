import CodeCore
import Foundation

/// Definitions and references per repo@head (PR workbench D2): what the
/// tags query names in every file of a tagged language at the head —
/// search-based navigation, never a language server. An ambiguous name
/// lists every candidate, ranked same file → imported files → same
/// directory → the rest.
///
/// The index, its ranking and its least-recently-used bound are the code
/// core's (`SymbolIndexes`, workbench WP3b): compact entries under each
/// name, at most `capacity` repo@heads. This actor owns the core's handle,
/// reads the mirror `chunk` files at a time so a large repo never holds
/// every text at once, and shares one build per repo@head. `purge` when the
/// panel releases its tree.
actor SymbolIndex {
    static let shared = SymbolIndex()

    typealias Symbol = CodeCore.Symbol

    static let capacity = SymbolIndexes.capacity
    /// A larger file is generated or minified: nobody navigates it.
    static let fileLimit = SymbolIndexes.fileLimit
    /// Files read from the mirror per step of a build, bounding the texts held at once.
    static let chunk = 500

    private let indexes = SymbolIndexes()
    private var flights: [String: Task<Void, Error>] = [:]

    private static func key(_ repo: String, _ head: String) -> String { "\(repo)@\(head)" }

    // MARK: - Building

    /// Indexes `files` as repo@head, replacing what it held: each file of a
    /// tagged language under `fileLimit` is parsed off the actor.
    func build(repo: String, head: String, files: [(path: String, text: String)]) async {
        do {
            let builder = try SymbolIndexBuilder()
            await Self.add(files, to: builder)
            indexes.install(builder, repo: repo, head: head)
        } catch {
            NSLog("pultik: symbol index %@@%@ not built: %@", repo, head, error.localizedDescription)
        }
    }

    /// Builds repo@head from the mirror unless it is built: backfills the
    /// head's tree (D3), lists it, and reads the tagged files `chunk` at a
    /// time, so a large repo never holds every text at once. Concurrent
    /// callers share one build.
    func build(repo: String, head: String, mirror: GitMirror = .shared, password: String?) async throws {
        let key = Self.key(repo, head)
        if indexes.isBuilt(repo: repo, head: head) { return }
        if let flight = flights[key] { return try await flight.value }
        let flight = Task {
            try await mirror.backfill(repo, head: head, password: password)
            let paths = try await mirror.paths(repo, head: head).filter { SyntaxLanguage(path: $0)?.hasTags == true }
            let builder = try SymbolIndexBuilder()
            for start in stride(from: 0, to: paths.count, by: Self.chunk) {
                let files = try await mirror.texts(repo, head: head, paths: Array(paths[start ..< min(start + Self.chunk, paths.count)]),
                                                   byteLimit: Self.fileLimit)
                await Self.add(files, to: builder)
            }
            self.indexes.install(builder, repo: repo, head: head)
        }
        flights[key] = flight
        defer { flights[key] = nil }
        try await flight.value
    }

    func isBuilt(repo: String, head: String) -> Bool {
        indexes.isBuilt(repo: repo, head: head)
    }

    /// Drops every index (the panel released its tree).
    func purge() {
        indexes.purge()
    }

    /// One batch's tags, parsed off the actor (the core takes up to four
    /// threads). A file that fails to parse is logged and left out: one bad
    /// file does not cost the repo its index.
    private static func add(_ files: [(path: String, text: String)], to builder: SymbolIndexBuilder) async {
        do {
            let failed = try await Task.detached(priority: .utility) { try builder.add(files) }.value
            for file in failed { NSLog("pultik: symbol index skipped %@: %@", file.path, file.reason) }
        } catch {
            NSLog("pultik: symbol index skipped %d files: %@", files.count, error.localizedDescription)
        }
    }

    // MARK: - Reading

    /// Where `name` is defined, best first: in `path` itself, in a file
    /// `imports` names (or inside an imported directory: a Go package, a
    /// TS barrel's folder), in `path`'s directory, then everywhere else;
    /// by path and line within a rank.
    func definitions(of name: String, repo: String, head: String, from path: String, imports: [String]) -> [Symbol] {
        indexes.definitions(of: name, repo: repo, head: head, from: path, imports: imports)
    }

    /// Every use of `name`, by path and line. A spot that also defines it
    /// is left out (Go's tags query names a type's own name as a reference).
    func references(of name: String, repo: String, head: String) -> [Symbol] {
        indexes.references(of: name, repo: repo, head: head)
    }

    // MARK: - Imports

    /// The repo paths a file imports, for ranking definitions: TS and JS
    /// relative modules (and an index barrel's folder), Go import paths'
    /// last two components, Rust `mod` files and `crate::` paths, PHP `use`
    /// classes as PSR-4 file suffixes. Best effort: an alias or a package
    /// resolves to nothing.
    static func imports(_ text: String, language: SyntaxLanguage, path: String) -> [String] {
        SymbolIndexes.imports(text, language: language, path: path)
    }

    /// `path` is a file `imports` names, or lies in a directory it names;
    /// both as path suffixes, since a Go import path or a PHP namespace names
    /// the tail of a repo path, not all of it.
    static func imported(_ path: String, by imports: [String]) -> Bool {
        SymbolIndexes.imported(path, by: imports)
    }
}
