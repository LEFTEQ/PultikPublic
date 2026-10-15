import Foundation

extension StatusStore {
    // MARK: - Firing alerts (Prometheus + Loki rules, WG mesh)

    /// Firing criticals the panel has not shown yet — the icon's bell counts
    /// them with the unread eve alerts. Warnings never badge.
    var unseenFiringCount: Int {
        FiringWatch.criticals(firingAlerts)
            .filter { !FiringSeenStore.shared.isSeen(FiringWatch.episodeKey($0)) }.count
    }

    /// The icon's one alert indicator: unread eve alerts plus unseen firing
    /// criticals, red whenever either carries a critical.
    var badgeAlertCount: Int { unreadAlertCount + unseenFiringCount }
    var badgeAlertCritical: Bool { unreadCriticalAlert || unseenFiringCount > 0 }

    /// Panel opened with the Firing section visible: every critical it
    /// shows counts as seen and leaves the badge.
    func markFiringSeen() {
        FiringSeenStore.shared.markSeen(FiringWatch.criticals(firingAlerts).map(FiringWatch.episodeKey))
        onChange?()
    }

    /// One answered fetch: shown in the rail, watched for critical
    /// transitions (notified unless muted), seen-state pruned. nil —
    /// Prometheus silent — empties the rail but tells the watch nothing, so
    /// an outage never announces a wave of resolves.
    func applyFiring(_ fetched: (alerts: [FiringAlert], answered: Set<FiringAlert.Source>)?) {
        recordFiringNeeds(fetched)
        guard let fetched else {
            firingAlerts = []
            return
        }
        firingAlerts = fetched.alerts
        let notices = firingWatch.update(fetched.alerts, answered: fetched.answered,
                                         quiet: { ProdWatch.shared.claims($0) })
        if preferences.notifyFiring {
            for notice in notices {
                Notifier.send(title: notice.title, body: notice.body, url: Notifier.firingPanelURL)
            }
        }
        if fetched.answered == [.prometheus, .loki] {
            FiringSeenStore.shared.prune(keeping: Set(FiringWatch.criticals(fetched.alerts).map(FiringWatch.episodeKey)))
        }
    }

    var notifyFiring: Bool {
        preferences.notifyFiring
    }

    /// Settings ▸ Panel: mute critical-firing notifications. The watch keeps
    /// running, so un-muting announces only what changes from then on.
    func setNotifyFiring(_ on: Bool) {
        mutate { $0.notifyFiring = on }
    }

    #if DEBUG

    func debugSetFiring(_ spec: String) {
        debugFiring = spec.split(separator: ",").map { item in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            let (severity, name) = parts.count == 2 ? (parts[0], parts[1]) : ("critical", parts[0])
            return FiringAlert(name: name, state: "firing", severity: severity,
                               summary: "\(name) (injected by panel-drive)", description: nil,
                               labels: ["alertname": name, "severity": severity,
                                        "app": "pultik", "environment": "debug"],
                               activeAt: Date(), source: .prometheus)
        }
        Task {
            let fetched = await MetricsClient.shared.firingAlerts()
            applyFiring((alerts: (fetched?.alerts ?? []) + debugFiring,
                         answered: fetched?.answered ?? [.prometheus, .loki]))
        }
    }
    #endif

    // MARK: - Infra metrics (mesh Prometheus)

    /// A dozen PromQL queries per refresh — by far the widest fan-out Pultík
    /// has, and worth the cheapest possible way back after a pause.
    func refreshInfraMetrics() async {
        let snapshotKey = infraSnapshotKey
        let servers = preferences.servers.map { (name: $0.name, instance: $0.ref) }
        let services = preferences.services.map { (name: $0.name, probe: $0.ref, host: $0.host, job: $0.job) }
        var lanesRefreshed = false
        await gated(.prometheus, probe: {
            await MetricsClient.shared.reachable()
                ? nil : .unreachable("prometheus not answering")
        }) {
            async let metrics = MetricsClient.shared.serverMetrics(servers: servers)
            async let statuses = MetricsClient.shared.serviceStatuses(services: services)
            (serverMetrics, serviceStatuses) = await (metrics, statuses)

            // Every configured server has node_exporter series and every
            // configured service a blackbox probe, so "asked about some, got
            // nothing back" is not an empty answer — it is no answer, and the
            // only failure signal these queries give.
            if !servers.isEmpty || !services.isEmpty,
               serverMetrics.isEmpty, serviceStatuses.isEmpty
            {
                laneBoard = CILaneBoard()
                firingAlerts = []
                recordFiringNeeds(nil)
                return .unreachable("no answer from Prometheus")
            }

            if isSectionVisible("firing") {
                let fetched = await MetricsClient.shared.firingAlerts()
                #if DEBUG
                applyFiring(fetched.map { (alerts: $0.alerts + debugFiring, answered: $0.answered) })
                #else
                applyFiring(fetched)
                #endif
            } else {
                firingAlerts = []
                NowStore.shared.forget(.estateAlerts)
            }

            if isSectionVisible("runners") {
                laneBoard = await MetricsClient.shared.laneBoard()
                lanesRefreshed = true
            } else {
                laneBoard = CILaneBoard()
            }
            recordInfraSnapshot(key: snapshotKey)
            return nil
        }
        // Each host's pool line is its own Semafor's, another host: its
        // failures back off on its own breaker instead of riding
        // Prometheus's success, and while it holds that host's line stays
        // hidden. Only a board this pass fetched is labelled — a board kept
        // through a Prometheus pause keeps its last pools rather than pairing
        // a new head with old lanes.
        guard lanesRefreshed, !laneBoard.isEmpty else { return }
        let lanes = laneBoard.lanes
        let semafors = preferences.servers.compactMap { server in server.semaforURL.map { (server.ref, $0) } }
        await withTaskGroup(of: Void.self) { group in
            for (host, base) in semafors {
                group.addTask { await self.refreshSemafor(host: host, base: base,
                                                          lanes: lanes.filter { $0.host == host }) }
            }
        }
        let configured = Set(semafors.map(\.0))
        laneBoard.pools = laneBoard.pools.filter { configured.contains($0.key) }
        ciThroughputs = ciThroughputs.filter { configured.contains($0.key) }
        recordInfraSnapshot(key: snapshotKey)
    }

    /// One host's Semafor behind its own breaker: the pool, and once a
    /// minute the day.
    private func refreshSemafor(host: String, base: URL, lanes: [CILane]) async {
        laneBoard.pools[host] = nil
        var answered = false
        await gated(.semafor(host: base.host() ?? base.absoluteString)) {
            let (pool, failure) = await SemaforClient.shared.pool(at: base, lanes: lanes)
            laneBoard.pools[host] = pool
            guard failure == nil else { return failure }
            answered = true
            // The overview is a day-scale read: once a minute, like Semafor's
            // own SPA. A failed overview hides its lines but is no reason to
            // back off the pool that just answered.
            if Date().timeIntervalSince(throughputFetchedAt[host] ?? .distantPast) >= Self.throughputInterval {
                let (throughput, overviewFailure) = await SemaforClient.shared.overview(at: base)
                ciThroughputs[host] = throughput
                throughputFetchedAt[host] = throughput == nil ? nil : Date()
                if let overviewFailure {
                    NSLog("pultik: semafor %@ overview — %@", host, String(describing: overviewFailure))
                }
            }
            return nil
        }
        if !answered {
            ciThroughputs[host] = nil
            throughputFetchedAt[host] = nil
        }
    }

    /// The CI day Home and Now show: ONE host's own (never a sum), the first
    /// server in Settings order whose Semafor answered, named.
    var ciDay: (host: String, throughput: CIThroughput)? {
        for server in preferences.servers {
            if let throughput = ciThroughputs[server.ref] { return (server.name, throughput) }
        }
        return nil
    }

    /// The Semafor that counts `host`'s lanes; nil for a host without one.
    func semaforBase(forHost host: String) -> URL? {
        preferences.servers.first { $0.ref == host }?.semaforURL
    }
}
