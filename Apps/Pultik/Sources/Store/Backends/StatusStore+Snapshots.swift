import Foundation

/// Each backend's last answer on disk (copilot shell D8, `QueryRepository`):
/// restored before the first poll so a cold start shows the last known state
/// with its age, recorded after every successful answer. Keys carry the
/// identity that fetched them — a credential digest, an origin, a host set —
/// so one account's state is never shown under another. Prod restored from
/// disk reads "as of HH:MM", never green, until Hlídač answers live.
extension StatusStore {
    struct InfraState: Codable, Sendable {
        var servers: [ServerMetrics]
        var services: [ServiceStatus]
        var firing: [FiringAlert]
        var lanes: CILaneBoard
        /// Each host's Semafor day, by the host's `ref`.
        var throughputs: [String: CIThroughput]
    }

    enum Snapshots {
        static let prod = QueryResource<HlidacDigest>(name: "hlidac.digest", staleAfter: 45)
        static let github = QueryResource<[RepoStatus]>(name: "github.repos", staleAfter: 180)
        static let infra = QueryResource<InfraState>(name: "infra.metrics", schema: 2, staleAfter: 180)
        /// One host's Semafor views, keyed by its base URL (vt-7727 D10).
        static let semafor = QueryResource<SemaforHostState>(name: "semafor.views", staleAfter: 180)
        // Each host × lens's newest 24 h of timeline (`semafor.timeline.<lens>`,
        // keyed by the host's base URL, vt-7781 D10) is
        // `TimelinePages.snapshotResource`: it writes them, and restores one
        // on its key's first ask — never here at launch, which would cost
        // their memory before any timeline shows.
    }

    // MARK: Keys

    var prodSnapshotKey: QueryKey? {
        hlidacBase.map { QueryKey(resource: Snapshots.prod.name, identity: $0.absoluteString) }
    }

    /// `slugs`: the pinned set a request ran for — captured before its awaits,
    /// so a pin change mid-flight can never file one set's answer under another.
    func githubSnapshotKey(identity: String, slugs: [String]) -> QueryKey {
        QueryKey(resource: Snapshots.github.name, identity: identity, scope: slugs.joined(separator: ","))
    }

    /// nil for the host example ships (its keys predate profiles and stay as
    /// they were), else the configured host's URL.
    static func hostIdentity(_ url: URL?, shipped: String) -> String? {
        let configured = url?.absoluteString ?? ""
        return configured == shipped ? nil : configured
    }

    /// Every query-relevant field of the configured servers and services —
    /// a probe's blackbox `job` decides its verdict — so a changed setting
    /// never restores the previous configuration's answer.
    var infraSnapshotKey: QueryKey {
        let servers = preferences.servers.map { "s|\($0.name)|\($0.ref)|\($0.semafor ?? "")" }
        let services = preferences.services.map { "p|\($0.name)|\($0.ref)|\($0.host ?? "")|\($0.job ?? "")" }
        // `firing` holds both Prometheus's and the Loki ruler's alerts, so
        // both hosts are the identity; example's pair keeps its old "mesh".
        let config = RuntimeConfig.current
        let shipped = Self.hostIdentity(config.prometheus, shipped: PultikProfile.example.prometheusURL) == nil
            && Self.hostIdentity(config.loki, shipped: PultikProfile.example.lokiURL) == nil
        let identity = shipped ? "mesh"
            : "\(config.prometheus?.absoluteString ?? "")\u{0}\(config.loki?.absoluteString ?? "")"
        return QueryKey(resource: Snapshots.infra.name, identity: identity,
                        scope: QueryKey.digest((servers + services).joined(separator: "\n")))
    }

    // MARK: Restore

    /// Before the first poll: every backend's last snapshot under the
    /// current identity, all at once — GitHub's identity is a `gh` process,
    /// and it must not hold back the rest. A value a live answer already
    /// replaced is left.
    func restoreSnapshots() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.restoreProd() }
            group.addTask { await self.restoreGitHub() }
            group.addTask { await self.restoreInfra() }
            group.addTask { await self.restoreSemafor() }
        }
        onChange?()
    }

    private func restoreProd() async {
        if let key = prodSnapshotKey, prodDigest == nil,
           let snapshot = await QueryRepository.shared.restore(Snapshots.prod, key: key), prodDigest == nil {
            prodDigest = snapshot.value
            prodRestoredAt = snapshot.fetchedAt
        }
    }

    private func restoreGitHub() async {
        if !pinned.isEmpty, let identity = try? await client.cacheIdentity(),
           let snapshot = await QueryRepository.shared.restore(Snapshots.github, key: githubSnapshotKey(identity: identity, slugs: pinned)),
           repos.isEmpty {
            repos = snapshot.value
            lastRefresh = snapshot.fetchedAt
            // The restored inbox names the operator's own rows: warm them too.
            warmPRMemory()
        }
    }

    private func restoreInfra() async {
        guard RuntimeConfig.current.prometheus != nil else { return }
        if let snapshot = await QueryRepository.shared.restore(Snapshots.infra, key: infraSnapshotKey),
           serverMetrics.isEmpty, serviceStatuses.isEmpty {
            let state = snapshot.value
            serverMetrics = state.servers
            serviceStatuses = state.services
            // Firing restores into the list, never into the watch: the first
            // live answer stays a silent baseline.
            firingAlerts = isSectionVisible("firing") ? state.firing : []
            laneBoard = isSectionVisible("runners") ? state.lanes : CILaneBoard()
            ciThroughputs = state.throughputs
        }
    }

    // MARK: Record

    func recordProdSnapshot(key: QueryKey?) {
        guard let key, let digest = prodDigest else { return }
        QueryRepository.shared.record(Snapshots.prod, key: key, value: digest)
    }

    func recordGitHubSnapshot(identity: String, slugs: [String]) {
        QueryRepository.shared.record(Snapshots.github, key: githubSnapshotKey(identity: identity, slugs: slugs),
                                      value: repos)
    }

    func recordInfraSnapshot(key: QueryKey) {
        QueryRepository.shared.record(Snapshots.infra, key: key,
                                      value: InfraState(servers: serverMetrics, services: serviceStatuses,
                                                        firing: firingAlerts, lanes: laneBoard,
                                                        throughputs: ciThroughputs))
    }
}
