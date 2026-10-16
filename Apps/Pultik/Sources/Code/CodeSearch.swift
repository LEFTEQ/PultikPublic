import CodeCore
import Foundation

/// Code search over a change request's head (PR workbench D3, S13): the
/// whole repo, not just the diff, read from the mirror — the head's tree
/// backfilled once, then `git grep` with match case, whole word and regex.
/// Foundation and CodeCore only, so the contract harness (which links the
/// core, `tools/test-foundation.sh`) runs `Tests/CodeSearchTests.swift`.
enum CodeSearch {
    /// Every hit of `query` at `head`, at most `GitMirror.grep`'s limit
    /// (exactly that many means there may be more). The first search of a
    /// head backfills its tree (one batched fetch, then a marker), later
    /// ones answer locally. `paths` narrows to those files (This PR); nil
    /// is the repo.
    static func search(repo: String, head: String, query: String, options: SearchOptions, paths: [String]? = nil,
                       mirror: GitMirror = .shared, password: String?) async throws -> [GrepHit] {
        guard !query.isEmpty else { return [] }
        try await mirror.backfill(repo, head: head, password: password)
        return try await mirror.grep(repo, head: head, query: query, options: options, paths: paths)
    }

    /// The identifier under UTF-16 `column` of `line` — what hover peeks and
    /// ⌘-click follows; nil off an identifier or on a number. Letters,
    /// digits, `_` and `$` (JavaScript, PHP) make an identifier (the code
    /// core's rule, workbench WP3b).
    static func wordAt(_ line: String, column: Int) -> String? {
        CodeText.wordAt(line, column: column)
    }
}
