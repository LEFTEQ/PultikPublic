import CodeThemes
import Foundation
import Observation

extension StatusStore {
    /// A blob's text for the code canvas (PR workbench WP2): the mirror
    /// holds both sides of every diff it computed, so this is a local read.
    /// Past `blobLimit` it throws — the file draws plain rather than parse a
    /// minified megabyte.
    func blobText(repo: String, sha: String) async throws -> String {
        let host = codeHost
        let identity = try await host.identity()
        try await GitMirror.shared.prepare(repo, remote: host.remoteURL(repo: repo))
        let data = try await GitMirror.shared.blob(repo, sha: sha, password: try await host.gitPassword(identity: identity))
        guard data.count <= Self.blobLimit else { throw CodeSourceTooLarge(bytes: data.count) }
        return String(decoding: data, as: UTF8.self)
    }

    static let blobLimit = 1 << 20

    /// A file at a commit — a file card's text (D2), local after a backfill.
    func fileText(repo: String, sha: String, path: String) async throws -> String {
        let host = codeHost
        let identity = try await host.identity()
        let text = try await GitMirror.shared.file(repo, path: path, at: sha, remote: host.remoteURL(repo: repo),
                                                   password: try await host.gitPassword(identity: identity))
        guard text.utf8.count <= Self.blobLimit else { throw CodeSourceTooLarge(bytes: text.utf8.count) }
        return text
    }

    /// The Commits tab's reads (PR workbench WP5): the mirror's log of
    /// `base..head` and one commit's own diff, persisted under the SHAs that
    /// name them — neither ever changes for its key.
    enum CodeResources {
        static let commits = QueryResource<[ChangeCommit]>(name: "pr.commits", staleAfter: .infinity, keep: 200)
        static let commitFiles = QueryResource<ChangeSet>(name: "pr.commitFiles", staleAfter: .infinity, keep: 100)
    }

    func prCommits(_ request: ChangeRequest) async throws -> [ChangeCommit] {
        let host = codeHost
        let identity = try await host.identity()
        let key = QueryKey(resource: CodeResources.commits.name, identity: identity,
                           scope: "\(request.ref.key)@\(request.baseSHA)..\(request.headSHA)")
        return try await QueryRepository.shared.load(CodeResources.commits, key: key, maxAge: .infinity) {
            let password = try await host.gitPassword(identity: identity)
            try await GitMirror.shared.prepare(request.ref.repo, remote: host.remoteURL(repo: request.ref.repo))
            return try await GitMirror.shared.log(request.ref.repo, base: request.baseSHA, head: request.headSHA,
                                                  password: password)
        }
    }

    /// Code search at the PR's head (D3): the first one backfills the head's
    /// blobs into the mirror, then `git grep` answers locally.
    func codeSearch(repo: String, head: String, query: String, options: SearchOptions,
                    paths: [String]?) async throws -> [GrepHit] {
        let host = codeHost
        let identity = try await host.identity()
        try await GitMirror.shared.prepare(repo, remote: host.remoteURL(repo: repo))
        return try await CodeSearch.search(repo: repo, head: head, query: query, options: options, paths: paths,
                                           mirror: GitMirror.shared, password: try await host.gitPassword(identity: identity))
    }

    /// F12 / ⇧F12 / ⌘-click (D2): builds the head's symbol index once, then
    /// ranks definitions by `path`'s own imports, or lists references.
    func lookUp(_ name: String, repo: String, head: String, from path: String,
                references: Bool) async throws -> [SymbolIndex.Symbol] {
        try await buildSymbolIndex(repo: repo, head: head)
        if references { return await SymbolIndex.shared.references(of: name, repo: repo, head: head) }
        let text = try await fileText(repo: repo, sha: head, path: path)
        let imports = SyntaxLanguage(path: path).map { SymbolIndex.imports(text, language: $0, path: path) } ?? []
        return await SymbolIndex.shared.definitions(of: name, repo: repo, head: head, from: path, imports: imports)
    }

    /// The hover peek: definitions only from an index already built.
    func peek(_ name: String, repo: String, head: String, from path: String) async -> [SymbolIndex.Symbol] {
        guard await SymbolIndex.shared.isBuilt(repo: repo, head: head) else { return [] }
        return await SymbolIndex.shared.definitions(of: name, repo: repo, head: head, from: path, imports: [])
    }

    /// Every tagged file at `head`, parsed once per head (the index
    /// backfills the tree and shares a build in flight).
    private func buildSymbolIndex(repo: String, head: String) async throws {
        guard !(await SymbolIndex.shared.isBuilt(repo: repo, head: head)) else { return }
        let host = codeHost
        let identity = try await host.identity()
        try await GitMirror.shared.prepare(repo, remote: host.remoteURL(repo: repo))
        try await SymbolIndex.shared.build(repo: repo, head: head, password: try await host.gitPassword(identity: identity))
    }

    func commitFiles(_ repo: String, sha: String) async throws -> ChangeSet {
        let host = codeHost
        let identity = try await host.identity()
        let key = QueryKey(resource: CodeResources.commitFiles.name, identity: identity, scope: "\(repo)@\(sha)")
        return try await QueryRepository.shared.load(CodeResources.commitFiles, key: key, maxAge: .infinity) {
            try await GitMirror.shared.commitChangeSet(repo, sha: sha, password: try await host.gitPassword(identity: identity))
        }
    }
}

struct CodeSourceTooLarge: Error, LocalizedError {
    let bytes: Int
    var errorDescription: String? { "\(bytes) bytes is past the highlighting limit" }
}

/// The code canvas's preferences: long lines wrap under the gutter until ⌥Z
/// turns it off (PR workbench D9, `codeUnwrapped`), and the code theme
/// (workbench WP4, `codeTheme`), both persisted in settings.json.
@MainActor
@Observable
final class CodePreferences {
    static let shared = CodePreferences()
    /// What an absent or unknown `codeTheme` draws: Codex Dark, the diff's
    /// look since the PR workbench, or Atom One Dark in a build without it
    /// (the public mirror leaves Codex Dark out).
    static let defaultThemes = ["codex-dark", "one-dark"]

    private(set) var wraps = Preferences.load().codeUnwrapped != true
    /// ⌘B: the side column (tree, search, references) beside the canvas.
    var sideColumnShown = true
    /// The selected code theme; every canvas and code background follows it live.
    let themes = CodeThemeStore(selectedID: Preferences.load().codeTheme, defaultIDs: CodePreferences.defaultThemes)

    func toggleWraps() {
        wraps.toggle()
        let unwrapped = !wraps
        Preferences.update { $0.codeUnwrapped = unwrapped ? true : nil }
    }

    /// Settings ▸ Code: switches every code surface now and saves the pick.
    func selectTheme(_ id: String) {
        guard themes.select(id) else { return }
        Preferences.update { $0.codeTheme = id }
    }
}
