import Foundation

/// Each backend's last answer on disk (copilot shell D8, `QueryRepository`):
/// restored before the first poll so a cold start shows the last known state
/// with its age, recorded after every successful answer. Keys carry the
/// identity that fetched them — a credential digest, an origin, a box set —
/// so one account's state is never shown under another. Prod restored from
/// disk reads "as of HH:MM", never green, until Hlídač answers live.
extension StatusStore {
    struct EveState: Codable, Sendable {
        var sessions: [EveSession]
        var alerts: [EveAlert]
        var approvals: [EveApproval]
    }

    struct InfraState: Codable, Sendable {
        var servers: [ServerMetrics]
        var services: [ServiceStatus]
        var firing: [FiringAlert]
        var lanes: CILaneBoard
        /// Each host's Semafor day, by the host's `ref`.
        var throughputs: [String: CIThroughput]
    }

    struct VitrinkaState: Codable, Sendable {
        var workspaces: [VitrinkaWorkspaceSnapshot]
        var todos: [TodoItem]
        var ripe: [TodoItem]
        /// Set by `VitrinkaClient.ripe()` after decoding, so `TodoItem`'s own
        /// coding never carries them; `isRipe` reads `reason == "milestone"`.
        var ripeReasons: [RipeReason]
    }

    /// The discovered boxes ride along: at launch discovery has not answered
    /// yet, and the snapshots must land on the boxes they came from.
    struct DevboxState: Codable, Sendable {
        var boxes: [DevboxEndpoint]
        var snapshots: [DevboxSnapshot]
    }

    struct RipeReason: Codable, Sendable {
        let id: Int64
        let reason: String?
        let milestoneName: String?
    }

    enum Snapshots {
        static let prod = QueryResource<HlidacDigest>(name: "hlidac.digest", staleAfter: 45)
        static let github = QueryResource<[RepoStatus]>(name: "github.repos", staleAfter: 180)
        static let eve = QueryResource<EveState>(name: "eve.ledger", schema: 2, staleAfter: 180)
        static let infra = QueryResource<InfraState>(name: "infra.metrics", schema: 2, staleAfter: 180)
        static let vitrinka = QueryResource<VitrinkaState>(name: "vitrinka.daily", staleAfter: 180)
        static let devbox = QueryResource<DevboxState>(name: "devbox.estate", schema: 2, staleAfter: 180)
        /// One host's Semafor views, keyed by its base URL (vt-7727 D10).
        static let semafor = QueryResource<SemaforHostState>(name: "semafor.views", staleAfter: 180)
    }

    // MARK: Keys

    var prodSnapshotKey: QueryKey? {
        hlidacConfigured ? QueryKey(resource: Snapshots.prod.name, identity: hlidacBase.absoluteString) : nil
    }

    /// `slugs`: the pinned set a request ran for — captured before its awaits,
    /// so a pin change mid-flight can never file one set's answer under another.
    func githubSnapshotKey(identity: String, slugs: [String]) -> QueryKey {
        QueryKey(resource: Snapshots.github.name, identity: identity, scope: slugs.joined(separator: ","))
    }

    func eveSnapshotKey(settingsToken: String?) async -> QueryKey {
        let token = await EveAuth.shared.token(preferred: settingsToken) ?? ""
        return QueryKey(resource: Snapshots.eve.name, identity: QueryKey.digest("eve\u{0}\(token)"))
    }

    /// Every query-relevant field of the configured servers and services —
    /// a probe's blackbox `job` decides its verdict — so a changed setting
    /// never restores the previous configuration's answer.
    var infraSnapshotKey: QueryKey {
        let servers = preferences.servers.map { "s|\($0.name)|\($0.ref)|\($0.semafor ?? "")" }
        let services = preferences.services.map { "p|\($0.name)|\($0.ref)|\($0.host ?? "")|\($0.job ?? "")" }
        return QueryKey(resource: Snapshots.infra.name, identity: "mesh",
                        scope: QueryKey.digest((servers + services).joined(separator: "\n")))
    }

    func vitrinkaSnapshotKey() async -> QueryKey? {
        guard let identity = await VitrinkaClient.shared.cacheIdentity() else { return nil }
        return QueryKey(resource: Snapshots.vitrinka.name, identity: identity, scope: vitrinkaWorkspace)
    }

    /// One ssh identity (`~/.ssh/pultik_devbox`) reaches every box this Mac
    /// discovers, so the mesh is the identity; the boxes are in the value.
    var devboxSnapshotKey: QueryKey {
        QueryKey(resource: Snapshots.devbox.name, identity: "mesh")
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
            group.addTask { await self.restoreEve() }
            group.addTask { await self.restoreInfra() }
            group.addTask { await self.restoreVitrinka() }
            group.addTask { await self.restoreDevbox() }
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
        }
    }

    private func restoreEve() async {
        if let snapshot = await QueryRepository.shared.restore(Snapshots.eve, key: await eveSnapshotKey(settingsToken: preferences.eveToken)),
           eveSessions.isEmpty, eveAlerts.isEmpty, eveApprovals.isEmpty {
            eveSessions = snapshot.value.sessions
            eveApprovals = snapshot.value.approvals
            eveAlerts = isSectionVisible("alerts") ? snapshot.value.alerts : []
        }
    }

    private func restoreInfra() async {
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

    private func restoreVitrinka() async {
        if let key = await vitrinkaSnapshotKey(),
           let snapshot = await QueryRepository.shared.restore(Snapshots.vitrinka, key: key), vitrinkaWorkspaces.isEmpty {
            if isSectionVisible("vitrinka") { vitrinkaWorkspaces = snapshot.value.workspaces }
            let reasons = Dictionary(snapshot.value.ripeReasons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ripe = snapshot.value.ripe.map { item -> TodoItem in
                var item = item
                item.reason = reasons[item.id]?.reason
                item.milestoneName = reasons[item.id]?.milestoneName
                return item
            }
            TodoStore.shared.restore(todos: snapshot.value.todos, ripe: ripe)
        }
    }

    private func restoreDevbox() async {
        if isSectionVisible("devbox"), devboxSnapshots.isEmpty,
           let snapshot = await QueryRepository.shared.restore(Snapshots.devbox, key: devboxSnapshotKey) {
            if devboxDiscoveredAt == nil, !snapshot.value.boxes.isEmpty { devboxBoxes = snapshot.value.boxes }
            for box in snapshot.value.snapshots where devboxBoxes.contains(box.endpoint) {
                devboxSnapshots[box.endpoint.name] = box
            }
            publishDevboxEstate()
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

    func recordEveSnapshot(key: QueryKey) {
        QueryRepository.shared.record(Snapshots.eve, key: key,
                                      value: EveState(sessions: eveSessions, alerts: eveAlerts, approvals: eveApprovals))
    }

    func recordInfraSnapshot(key: QueryKey) {
        QueryRepository.shared.record(Snapshots.infra, key: key,
                                      value: InfraState(servers: serverMetrics, services: serviceStatuses,
                                                        firing: firingAlerts, lanes: laneBoard,
                                                        throughputs: ciThroughputs))
    }

    func recordVitrinkaSnapshot(key: QueryKey?) {
        guard let key else { return }
        QueryRepository.shared.record(Snapshots.vitrinka, key: key,
                                      value: VitrinkaState(workspaces: vitrinkaWorkspaces,
                                                           todos: TodoStore.shared.todos,
                                                           ripe: TodoStore.shared.ripeNow,
                                                           ripeReasons: TodoStore.shared.ripeNow.map {
                                                               RipeReason(id: $0.id, reason: $0.reason,
                                                                          milestoneName: $0.milestoneName)
                                                           }))
    }

    func recordDevboxSnapshot() {
        let boxes = devboxSnapshots.values.sorted { $0.endpoint.name < $1.endpoint.name }
        guard !boxes.isEmpty else { return }
        QueryRepository.shared.record(Snapshots.devbox, key: devboxSnapshotKey,
                                      value: DevboxState(boxes: devboxBoxes, snapshots: boxes))
    }
}
