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

    /// eve's notification ledger in the watched lanes, under the credential
    /// that read it (`eveSnapshotKey`); nil = it did not answer.
    func recordEveNeeds(_ alerts: [EveAlert]?, account: String) {
        let now = Date()
        NowStore.shared.record(NowAdapters.eveNotifications(alerts, lanes: Set(preferences.visibleAlertLanes),
                                                            origin: EveNotificationsClient.origin, account: account,
                                                            now: now), now: now)
    }

    /// eve's parked approvals under the credential that read them; nil = the
    /// approvals read did not answer.
    func recordEveApprovalNeeds(_ approvals: [EveApproval]?, account: String) {
        let now = Date()
        NowStore.shared.record(NowAdapters.eveApprovals(approvals, origin: EveNotificationsClient.origin,
                                                        account: account, now: now), now: now)
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

    /// The todo engine's ripe and scheduled todos under the sign-in that
    /// read them (`VitrinkaClient.cacheIdentity`); `answered` false = the
    /// vitrinka pass failed or was held. No sign-in, no account's needs:
    /// the feed is forgotten rather than left showing the last one's.
    func recordTodoNeeds(answered: Bool, account: String?) {
        guard let account else {
            NowStore.shared.forget(.vitrinkaTodos)
            return
        }
        let client = VitrinkaClient.shared
        let todos = answered ? TodoStore.shared.reminderCandidates.map(NowInputs.Todo.init) : nil
        let now = Date()
        NowStore.shared.record(NowAdapters.ripeTodos(todos, origin: client.origin, workspace: client.workspace ?? "default",
                                                     account: account, now: now), now: now)
    }

    /// Stale parked workspaces across every box that answered this pass.
    func recordDevboxNeeds(answered: Int, of boxes: Int) {
        let now = Date()
        NowStore.shared.record(NowAdapters.staleWorkspaces(answered > 0 ? devboxWorkspaces : nil,
                                                           complete: answered == boxes, now: now), now: now)
    }
}

extension NowInputs.Todo {
    init(_ item: TodoItem) {
        self.init(id: item.id, project: item.project, title: item.title, status: item.status, dueAt: item.dueAt,
                  lead: item.lead, reason: item.reason, url: item.url.absoluteString)
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
