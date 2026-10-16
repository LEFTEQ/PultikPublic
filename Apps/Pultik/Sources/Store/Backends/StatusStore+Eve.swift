import Foundation

extension StatusStore {
    // MARK: - Eve alerts (notifications ledger, WG mesh)

    /// Alerts in the lanes the user actually watches — newest first, as the
    /// ledger returns them. Every alert surface (rail, bar cell, badge,
    /// notify) works off this filtered view.
    var visibleAlerts: [EveAlert] {
        let lanes = Set(preferences.visibleAlertLanes)
        return eveAlerts.filter { lanes.contains($0.category) }
    }

    /// When eve last answered, while that answer is a restored snapshot or
    /// older than its schedule (a held breaker); nil while it is live. Its
    /// approvals are then last known: "as of", never a live signal.
    var eveLastKnownAt: Date? {
        guard let freshness = QueryRepository.shared.freshness[Snapshots.eve.name],
              freshness.isStale(after: Snapshots.eve.staleAfter) else { return nil }
        return freshness.fetchedAt
    }

    var unreadAlertIds: Set<Int> {
        Set(visibleAlerts.map(\.id).filter { !AlertSeenStore.shared.isSeen($0) })
    }

    var unreadAlertCount: Int {
        unreadAlertIds.count
    }

    /// A critical alert is unread — the badge and the bar cell go red.
    var unreadCriticalAlert: Bool {
        let unread = unreadAlertIds
        return visibleAlerts.contains { $0.severity == .critical && unread.contains($0.id) }
    }

    /// Panel opened with the alerts section visible — everything currently
    /// shown counts as seen. The badge clears; the rail keeps its unread
    /// styling from the snapshot the panel took before calling this.
    func markAlertsSeen() {
        AlertSeenStore.shared.markSeen(visibleAlerts.map(\.id))
        onChange?()
    }

    /// Both eve rails — PR sessions and the alerts ledger — behind ONE
    /// breaker: same host, so a refusal on either is a refusal for both, and
    /// the health endpoint is the cheapest way back in.
    func refreshEve() async {
        // One credential for the whole pass: both reads and the snapshot key,
        // so a token changed mid-flight never files one account's answer
        // under another.
        let token = eveToken
        let snapshotKey = eveSnapshotKey(settingsToken: token)
        await gated(.eve, probe: {
            await EveClient.shared.probeHealth(settingsToken: token)
        }) {
            var failure: ProbeFailure?
            switch await EveClient.shared.prSessions(settingsToken: token) {
            case let .failed(why): failure = why
            case let .value(sessions): eveSessions = sessions
            }
            switch await EveClient.shared.approvals(settingsToken: token) {
            case let .failed(why):
                failure = failure ?? why
                recordEveApprovalNeeds(nil, account: snapshotKey.identity)
            case let .value(approvals):
                eveApprovals = approvals
                recordEveApprovalNeeds(approvals, account: snapshotKey.identity)
            }
            // The ledger's verdict wins when it has one — it distinguishes a
            // refusal from silence, which the sessions call cannot.
            let verdict = await refreshEveAlerts(settingsToken: token, account: snapshotKey.identity) ?? failure
            if verdict == nil { recordEveSnapshot(key: snapshotKey) }
            return verdict
        }
    }

    /// `account`: the credential digest the pass captured, so Now files the
    /// answer under the token that read it.
    func refreshEveAlerts(settingsToken token: String?, account: String) async -> ProbeFailure? {
        guard isSectionVisible("alerts") else {
            eveAlerts = []
            NowStore.shared.forget(.eveNotifications)
            return nil
        }
        // .failed = the fetch FAILED (off-mesh, endpoint absent): keep the last
        // known list, or a transient failure would resurrect every alert as
        // "new" on recovery. An EMPTY array is a real answer — the ledger is
        // clear — and must be allowed to empty the rail.
        let fetched: [EveAlert]
        switch await EveNotificationsClient.shared.recent(settingsToken: token) {
        case let .failed(failure):
            recordEveNeeds(nil, account: account)
            return failure
        case let .value(alerts): fetched = alerts
        }
        recordEveNeeds(fetched, account: account)
        let lanes = Set(preferences.visibleAlertLanes)
        if let notified = notifiedAlertIds {
            for alert in fetched.reversed()
                where lanes.contains(alert.category) && !notified.contains(alert.id)
            {
                Notifier.send(
                    title: "eve · \(alert.category)\(alert.severity == .critical ? " — critical" : "")",
                    body: alert.title,
                    url: nil
                )
            }
        }
        notifiedAlertIds = (notifiedAlertIds ?? []).union(fetched.map(\.id))
        eveAlerts = fetched
        if let floor = fetched.map(\.id).min() {
            AlertSeenStore.shared.prune(keepingAtOrAbove: floor)
        }
        onChange?()
        return nil
    }
}
