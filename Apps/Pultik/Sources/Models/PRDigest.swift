import Foundation

/// Home's Pull requests tile (panel Home D3, 2026-10-07): the inbox folded to
/// what needs you. Needs-you PRs (`attentionRank` 0–1: failing checks,
/// changes requested, review awaited, checks running) stay rows; each repo's
/// ready PRs fold to one counted line; drafts and stale PRs share one fold at
/// the bottom. Needs-you beats stale — a red PR nobody touched for a week is
/// still red — and a draft always folds. Repos keep the inbox's fixed order.
///
/// Generic over the inbox entry so the rules are Foundation-tested without
/// the store; the caller says where each entry's repo and PR live.
struct PRDigest<Entry> {
    struct Repo {
        let slug: String
        let needsYou: [Entry]
        let ready: [Entry]
    }

    /// Repos with at least one needs-you or ready PR, in inbox order.
    let repos: [Repo]
    let drafts: [Entry]
    let stale: [Entry]
    let total: Int

    var needsYouCount: Int { repos.reduce(0) { $0 + $1.needsYou.count } }
    var readyCount: Int { repos.reduce(0) { $0 + $1.ready.count } }

    /// The expansion key of the drafts · stale fold; a repo's ready line
    /// expands under its slug.
    static var foldKey: String { "·drafts-stale" }

    /// The rows on screen, in drawing order, given which folds are open —
    /// the panel's keyboard selection walks exactly these.
    func visible(expanded: Set<String>) -> [Entry] {
        repos.flatMap { $0.needsYou + (expanded.contains($0.slug) ? $0.ready : []) }
            + (expanded.contains(Self.foldKey) ? drafts + stale : [])
    }

    /// No update for this long and nothing asks for you → stale.
    static var staleAfter: TimeInterval { 7 * 24 * 3600 }

    init(_ entries: [Entry], repo: (Entry) -> String, info: (Entry) -> PRInfo, now: Date = Date()) {
        var order: [String] = []
        var needsYou: [String: [Entry]] = [:]
        var ready: [String: [Entry]] = [:]
        var drafts: [Entry] = []
        var stale: [Entry] = []
        for entry in entries {
            let pr = info(entry)
            let slug = repo(entry)
            if pr.isDraft {
                drafts.append(entry)
            } else if pr.attentionRank <= 1 {
                needsYou[slug, default: []].append(entry)
                if !order.contains(slug) { order.append(slug) }
            } else if let updated = pr.pr.updatedAt, now.timeIntervalSince(updated) >= Self.staleAfter {
                stale.append(entry)
            } else {
                ready[slug, default: []].append(entry)
                if !order.contains(slug) { order.append(slug) }
            }
        }
        // The inbox is grouped by repo in its fixed order, so first-seen
        // order is that order.
        repos = order.map { Repo(slug: $0, needsYou: needsYou[$0] ?? [], ready: ready[$0] ?? []) }
        self.drafts = drafts
        self.stale = stale
        total = entries.count
    }
}
