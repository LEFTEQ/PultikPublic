import Foundation

// The Now queue's feed (copilot shell WP4): each lane hands its fresh read to
// `NowStore` right where its answer lands. A restored or held value is never
// a read — a lane that did not answer records nil (`.failed`), and Now keeps
// its last needs without clearing any. The app types the Foundation adapters
// never see are bridged into `NowInputs` here.

extension StatusStore {
    /// Hlídač's host — the origin every prod incident key carries.
    var hlidacOrigin: String {
        hlidacBase.map { $0.host() ?? $0.absoluteString } ?? ""
    }

    /// The prod lane: Hlídač's blindness and its Sentry issues. `answered`:
    /// the digest on screen came from this pass, not from a restore.
    func recordProdNeeds(answered: Bool) {
        guard hlidacConfigured else {
            NowStore.shared.forget(.hlidacBlindness)
            NowStore.shared.forget(.hlidacSentry)
            return
        }
        let digest = answered ? prodDigest : nil
        let now = Date()
        NowStore.shared.record(NowAdapters.hlidacBlindness(digest: digest, unreachableSince: prodUnreachableSince,
                                                           origin: hlidacOrigin, now: now), now: now)
        NowStore.shared.record(NowAdapters.hlidacSentry(digest: digest, unreachableSince: prodUnreachableSince,
                                                        origin: hlidacOrigin, now: now), now: now)
    }

    /// The infra lane's firing rules; nil = Prometheus did not answer. A
    /// silent Loki ruler makes the read partial.
    func recordFiringNeeds(_ fetched: (alerts: [FiringAlert], answered: Set<FiringAlert.Source>)?) {
        let now = Date()
        NowStore.shared.record(NowAdapters.estateAlerts(
            fetched?.alerts, complete: fetched?.answered == [.prometheus, .loki], digest: prodDigest,
            unreachableSince: prodUnconfirmedSince, pointers: preferences.prodPointers,
            hlidacOrigin: hlidacOrigin, origin: MetricsClient.origin, now: now), now: now)
    }

    /// Stale PRs from the estate read, under the credential that read it. A
    /// repo the estate did not answer for keeps its last PRs but makes the
    /// read partial; nil = the estate read failed. No identity, no account's
    /// needs: the feed is forgotten.
    func recordStalePRNeeds(_ repos: [RepoStatus]?, answered: Set<String>, identity: String?) {
        guard let identity else {
            NowStore.shared.forget(.githubStalePRs)
            return
        }
        let seen = repos?.map { repo -> RepoStatus in
            var repo = repo
            if !answered.contains(repo.slug), repo.error == nil { repo.error = "missing from the estate read" }
            return repo
        }
        let now = Date()
        NowStore.shared.record(NowAdapters.stalePRs(seen, login: identity, now: now), now: now)
    }
}

extension NowInputs.MacReport {
    init(_ health: MacHealth) {
        self.init(generatedAt: health.generatedAt, findings: health.findings.map { finding in
            NowInputs.MacFinding(id: finding.id, severity: NowInputs.MacFinding.Severity(finding.severity),
                                 title: finding.title, detail: finding.detail, since: finding.since,
                                 stopSupported: finding.stop.supported)
        })
    }
}

extension NowInputs.MacFinding.Severity {
    init(_ severity: MacHealth.Severity) {
        switch severity {
        case .red: self = .red
        case .amber: self = .amber
        case .info: self = .info
        case .ok: self = .ok
        }
    }
}
