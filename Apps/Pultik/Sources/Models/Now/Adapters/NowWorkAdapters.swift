import Foundation

// The operator's work source: stale PRs. Ordinary state — running
// checks, generic awaiting reviews — never becomes a need.

extension NowAdapters {
    /// A non-draft PR nothing else asks you about (`PRDigest`'s ready set),
    /// untouched for `PRDigest.staleAfter`: it drifts from `updatedAt + 7 d`.
    /// A repo whose estate read failed, or that filled the estate's capped
    /// open list (the least recently touched — the stale ones — fall off
    /// first), makes the read partial.
    static func stalePRs(_ repos: [RepoStatus]?, host: String = "github.com", login: String, now: Date) -> NowRead {
        let source = NowSource(feed: .githubStalePRs, identity: "\(host)/\(login)")
        guard let repos else { return failed(source) }
        var needs: [NowNeed] = []
        for repo in repos {
            for info in repo.prs where !info.isDraft && info.attentionRank >= 2 {
                guard let updated = info.pr.updatedAt else { continue }
                let staleAt = updated.addingTimeInterval(PRDigest<PRInfo>.staleAfter)
                guard staleAt <= now else { continue }
                let incident = "github:\(host):\(repo.slug):pr:\(info.pr.number)"
                needs.append(NowNeed(
                    needID: "\(incident):stale", incidentKey: incident, kind: .stalePR, lane: .drifting,
                    severity: .normal, onset: .exact(staleAt), title: info.pr.title, subtitle: repo.slug,
                    displayID: "#\(info.pr.number)", verb: .open("Inspect PR"),
                    target: NowTarget(module: .prs, objectID: "pr:\(info.pr.id)", url: info.pr.htmlUrl)))
            }
        }
        let partial = repos.contains { $0.error != nil || $0.prs.count >= ChangeRequestInbox.openLimit }
        return NowRead(source: source, coverage: partial ? .partial : .complete, needs: needs)
    }
}
