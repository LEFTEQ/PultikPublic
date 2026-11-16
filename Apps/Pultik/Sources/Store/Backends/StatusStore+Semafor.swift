import Foundation

/// Every host's Semafor (vt-7727 WP3): one lane, each host behind its own
/// breaker (`gated(.semafor(host:))`), reading only what the view on screen
/// draws — Home's day and estate, CI's view for the host chip, Estate's
/// map, findings and backups — and nothing while the panel is hidden (D10).
/// Each read has its own age before it is read again; each host's answer
/// is snapshotted, so a view paints at once and says "as of" while its
/// Semafor is not answering.
extension StatusStore {
    /// One read the lane can make, with how old its answer may grow on
    /// screen before it is read again.
    enum SemaforRead: String, CaseIterable, Sendable {
        case admission, overview, map, findings, backups, lanes, live, runs, workflows, failures
        /// Read on entering the Map only (`enterEstateMap`), never polled.
        case topology

        func maxAge(on module: PanelModule) -> TimeInterval {
            switch self {
            case .admission: 0
            case .live: 10
            case .overview: StatusStore.throughputInterval
            case .map, .findings: module == .estate ? 30 : 60
            case .backups: module == .estate ? 60 : 300
            case .runs: 30
            case .lanes, .workflows, .failures, .topology: 300
            }
        }
    }

    /// The hosts with a Semafor, in Settings order.
    var semaforServers: [(host: String, base: URL)] {
        preferences.servers.compactMap { server in server.semaforURL.map { (server.ref, $0) } }
    }

    /// Each host's state in Settings order — the shape `SemaforCI` reads.
    var semaforStates: [(host: String, state: SemaforHostState)] {
        semaforServers.map { ($0.host, semaforHosts[$0.host] ?? SemaforHostState()) }
    }

    /// CI's host (D6): the operator's pick while it is configured, else the
    /// host with the most fleet jobs in its timeline window's newest hour.
    var ciSemaforHost: String? {
        let hosts = semaforServers.map(\.host)
        if let choice = ciHostChoice, hosts.contains(choice) { return choice }
        let windows = hosts.map { host in (host, timelineWindow(TimelineKey(host: host, lens: .ci))) }
        return SemaforCI.busiestHost(windows.map { ($0.0, $0.1?.jobs ?? [], $0.1?.now) }) ?? hosts.first
    }

    func setCIHost(_ host: String) {
        ciHostChoice = host
        kickSemafor()
    }

    /// The lane's interval: nothing while hidden, the live edge's 10 s while
    /// a timeline shows, the shared cadence otherwise.
    func semaforInterval(cadence: TimeInterval) -> TimeInterval {
        guard let module = visibleModule, Self.moduleLanes[module]?.contains("semafor") == true else { return 3600 }
        if timelineVisibility != nil { return 10 }
        return min(cadence, visibleCadence("semafor") ?? cadence)
    }

    /// What is on screen changed: read what it needs now, not at the next tick.
    func kickSemafor() {
        guard pollingStarted else { return }
        Task { await schedule.run("semafor") }
    }

    /// What `host` must read for the view on screen, minus what is still young.
    func semaforReads(host: String, module: PanelModule, view: ModuleView?, now: Date = Date()) -> [SemaforRead] {
        var reads: [SemaforRead] = []
        // Backups is read on entering, never polled (vt-7781 D10).
        var onEntering = false
        switch module {
        case .home:
            reads = [.overview, .map, .findings, .backups]
        case .estate:
            reads = [.map, .findings, .backups]
            onEntering = view == .backups
        case .ci:
            // Every host's lanes decide which reads the hosted lanes (D14).
            reads = [.admission, .overview, .lanes]
            if host == ciSemaforHost {
                switch view ?? .timeline {
                case .runs: reads.append(.runs)
                case .workflows: reads.append(.workflows)
                case .failures: reads.append(.failures)
                // The timeline's edge is `TimelinePages`' (`timelineVisibility`); Fleet draws the lanes
                // and Prometheus' board. Nothing reads the old live edge since Live retired (WP6).
                case .timeline, .fleet, .machines, .map, .backups: break
                }
            }
        default:
            break
        }
        let state = semaforHosts[host]
        return reads.filter { read in
            guard let at = state?.fetchedAt[read.rawValue] else { return true }
            if onEntering { return at < visibleSince }
            return now.timeIntervalSince(at) >= read.maxAge(on: module)
        }
    }

    func refreshSemafor() async {
        guard let module = visibleModule else { return }
        let view = visibleView
        let servers = semaforServers
        await withTaskGroup(of: Void.self) { group in
            for (host, base) in servers {
                let reads = semaforReads(host: host, module: module, view: view)
                guard !reads.isEmpty else { continue }
                group.addTask { await self.refreshSemafor(host: host, base: base, reads: reads) }
            }
        }
        await requestVisibleTimelines()
        let configured = Set(servers.map(\.host))
        semaforHosts = semaforHosts.filter { configured.contains($0.key) }
        laneBoard.pools = laneBoard.pools.filter { configured.contains($0.key) }
        ciThroughputs = ciThroughputs.filter { configured.contains($0.key) }
    }

    /// One host's reads behind its breaker, in order; the first failure
    /// stops the pass and backs the host off. The overview alone never
    /// does: a failed day hides its lines, not the pool that answered.
    private func refreshSemafor(host: String, base: URL, reads: [SemaforRead]) async {
        var state = semaforHosts[host] ?? SemaforHostState()
        let client = SemaforClient.shared
        var answered = false
        await gated(.semafor(host: base.host() ?? base.absoluteString)) {
            for read in reads {
                var failure: ProbeFailure?
                switch read {
                case .admission:
                    let (pool, why) = await client.pool(at: base, lanes: laneBoard.lanes.filter { $0.host == host })
                    laneBoard.pools[host] = pool
                    failure = why
                case .overview:
                    let (throughput, why) = await client.overview(at: base)
                    ciThroughputs[host] = throughput
                    throughputFetchedAt[host] = throughput == nil ? nil : Date()
                    if let why { NSLog("pultik: semafor %@ overview — %@", host, String(describing: why)) }
                    if throughput == nil { continue }
                case .map:
                    let (value, why) = await client.estateMap(at: base)
                    if let value { state.map = value }
                    failure = why
                case .findings:
                    let (value, why) = await client.findings(at: base)
                    if let value { state.findings = value }
                    failure = why
                case .backups:
                    let (value, why) = await client.backups(at: base)
                    if let value { state.backups = value }
                    failure = why
                case .lanes:
                    let (value, why) = await client.lanes(at: base)
                    if let value { state.lanes = value }
                    failure = why
                case .live:
                    let (value, why) = await client.liveEdge(at: base)
                    if let value { state.liveEdge = value }
                    failure = why
                case .runs:
                    let (value, why) = await client.runs(at: base)
                    if let value { state.runs = value }
                    failure = why
                case .workflows:
                    let (value, why) = await client.workflows(at: base)
                    if let value { state.workflows = value }
                    failure = why
                case .failures:
                    let (value, why) = await client.failures(at: base)
                    if let value { state.failures = value }
                    failure = why
                case .topology:
                    let (value, why) = await client.topology(at: base)
                    if let value { state.topology = value }
                    failure = why
                }
                if let failure { return failure }
                state.fetchedAt[read.rawValue] = Date()
                answered = true
            }
            return nil
        }
        if answered {
            state.unreachableSince = nil
        } else if state.unreachableSince == nil {
            state.unreachableSince = Date()
        }
        semaforHosts[host] = state
        if answered { recordSemaforSnapshot(host: host, base: base) }
    }

    // MARK: - A run's graph (read on selection)

    static func runDetailKey(host: String, runID: Int64) -> String { "\(host)/\(runID)" }

    /// The run's jobs, needs graph and critical path from `host`'s Semafor,
    /// once per selection while it is not settled; never polled.
    func loadRunDetail(host: String, runID: Int64) async {
        let key = Self.runDetailKey(host: host, runID: runID)
        if let known = semaforRunDetails[key], known.criticalPath?.seconds != nil { return }
        guard let base = semaforServers.first(where: { $0.host == host })?.base else { return }
        await gated(.semafor(host: base.host() ?? base.absoluteString)) {
            let (detail, failure) = await SemaforClient.shared.run(at: base, id: runID)
            if let detail { semaforRunDetails[key] = detail }
            return failure
        }
    }

    // MARK: - Timelines (vt-7781 WP4)

    /// The keys `lens` reads (D6, D14): CI the chip's host and the hosted
    /// source; the estate and backups every host, each for its own boxes.
    func timelineKeys(_ lens: TimelineLens) -> [TimelineKey] {
        TimelineVisibility.keys(lens, ciHost: ciSemaforHost, hostedSource: SemaforCI.hostedSource(semaforStates),
                                hosts: semaforServers.map(\.host))
    }

    func timelineWindow(_ key: TimelineKey) -> TimelineWindow? {
        timelinePages.window(for: key)
    }

    /// The CI timeline's jobs, sorted by (start, id): the chip host's fleet
    /// jobs and the hosted source's hosted jobs, each once (D14).
    var ciTimelineJobs: [CITimelineJob] {
        let source = SemaforCI.hostedSource(semaforStates)
        let chip = ciSemaforHost.flatMap { timelineWindow(TimelineKey(host: $0, lens: .ci)) }
        let hosted = source.flatMap { timelineWindow(TimelineKey(host: $0, lens: .ci)) } ?? chip
        return SemaforCI.timelineJobs(fleet: chip?.jobs ?? [], hosted: hosted?.jobs ?? [])
    }

    /// The view's input: the timeline on screen and its time range, nil
    /// when none shows. While set (and the panel up) the lane reads its
    /// edge every 10 s; a moved range loads what it is missing now —
    /// coalesced, so a pan that sets it every frame costs one load at a time.
    func setTimelineVisibility(_ visibility: TimelineVisibility?) {
        guard visibility != timelineVisibility else { return }
        let shown = timelineVisibility != nil
        timelineVisibility = visibility
        guard visibility != nil else { return }
        if !shown { schedule.nudge() }
        loadVisibleTimelines()
    }

    private func loadVisibleTimelines() {
        guard timelineLoad == nil else {
            timelineLoadAgain = true
            return
        }
        timelineLoad = Task { [weak self] in
            guard let self else { return }
            repeat {
                timelineLoadAgain = false
                await requestVisibleTimelines()
            } while timelineLoadAgain && timelineVisibility != nil
            timelineLoad = nil
        }
    }

    /// What the visible timeline is missing, every key at once — the lane's
    /// pass and a moved range both come here; hidden, nothing.
    func requestVisibleTimelines() async {
        guard pollingStarted, visibleModule != nil, let visibility = timelineVisibility else { return }
        let pages = timelinePages
        await withTaskGroup(of: Void.self) { group in
            for key in timelineKeys(visibility.lens) {
                group.addTask { await pages.request(key, range: visibility.range, density: visibility.density) }
            }
        }
    }

    /// The panel's 30 s tree release: every loaded page goes (the 24 h
    /// snapshots stay on disk), and so does the replay.
    func releaseTimelines() {
        timelineVisibility = nil
        timelineReplay = nil
        timelinePages.purge()
    }

    /// The playhead (`ReplayClock` throttles it): what `lens` replays at
    /// `instant`, from each host it draws, read on request and never polled;
    /// nil returns to live, and nothing read before that lands after it.
    /// One read is in flight at a time and the newest instant asked meanwhile
    /// goes next: the throttle bounds the rate, this the concurrency — an
    /// `/estate/map?at=` takes ~0.9 s on build-server, and a held ← stacked them
    /// until its Semafor answered 502.
    func replayTimeline(_ lens: TimelineLens, at instant: Date?) async {
        guard let instant else {
            timelineReplayAsk &+= 1
            timelineReplayNext = nil
            timelineReplay = nil
            return
        }
        timelineReplayNext = (lens, instant)
        guard !timelineReplayInFlight else { return }
        timelineReplayInFlight = true
        defer { timelineReplayInFlight = false }
        while let next = timelineReplayNext {
            timelineReplayNext = nil
            let live = timelineReplayAsk
            let state = await replayState(next.lens, at: next.at)
            guard live == timelineReplayAsk, visibleModule != nil else { continue }
            timelineReplay = state
        }
    }

    private func replayState(_ lens: TimelineLens, at instant: Date) async -> TimelineReplay {
        let hosts = timelineKeys(lens).compactMap { key in semaforServers.first { $0.host == key.host } }
            .filter { lens != .ci || $0.host == ciSemaforHost }
        var state = TimelineReplay(lens: lens, at: instant)
        await withTaskGroup(of: (String, TimelineReplay?).self) { group in
            for (host, base) in hosts {
                group.addTask { (host, await self.replayRead(lens, at: instant, host: host, base: base)) }
            }
            for await (host, answer) in group {
                if let ci = answer?.ci[host] { state.ci[host] = ci }
                if let map = answer?.maps[host] { state.maps[host] = map }
                if let backups = answer?.backups[host] { state.backups[host] = backups }
            }
        }
        return state
    }

    private func replayRead(_ lens: TimelineLens, at instant: Date, host: String, base: URL) async -> TimelineReplay? {
        var read: TimelineReplay?
        await gated(.semafor(host: base.host() ?? base.absoluteString)) {
            let client = SemaforClient.shared
            var answer = TimelineReplay(lens: lens, at: instant)
            let failure: ProbeFailure?
            switch lens {
            case .ci:
                let (value, why) = await client.ciAt(at: base, instant: instant)
                answer.ci[host] = value
                failure = why
            case .estate:
                let (value, why) = await client.estateMap(at: base, instant: instant)
                answer.maps[host] = value
                failure = why
            case .backups:
                let (value, why) = await client.backups(at: base, instant: instant)
                answer.backups[host] = value
                failure = why
            }
            if failure == nil { read = answer }
            return failure
        }
        return read
    }

    /// The Map view was entered (D10): each host's topology and live map,
    /// read now and never polled — a re-entry within 5 s reads nothing.
    func enterEstateMap() async {
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for (host, base) in semaforServers {
                let reads = [SemaforRead.topology, .map].filter { read in
                    now.timeIntervalSince(semaforHosts[host]?.fetchedAt[read.rawValue] ?? .distantPast) >= 5
                }
                guard !reads.isEmpty else { continue }
                group.addTask { await self.refreshSemafor(host: host, base: base, reads: reads) }
            }
        }
    }

    /// One page for `TimelinePages`, behind the host's breaker; a held
    /// breaker or an unknown host asks nothing.
    func fetchTimelinePage(_ query: TimelineQuery) async -> TimelineAnswer {
        guard let base = semaforServers.first(where: { $0.host == query.key.host })?.base else { return .held }
        let kind = query.edge ? "edge" : query.bucket == nil ? "page" : "bins"
        var answer = TimelineAnswer.held
        await gated(.semafor(host: base.host() ?? base.absoluteString)) {
            let client = SemaforClient.shared
            switch query.key.lens {
            case .ci:
                let (page, bytes, failure) = await client.ciTimeline(at: base, before: query.before, span: query.span,
                                                                     bucket: query.bucket, counter: "ci/timeline:\(kind)")
                answer = page.map { .page(.ci($0), bytes: bytes) } ?? failure.map { .failed($0) } ?? .held
                return failure
            case .estate, .backups:
                let view = query.key.lens.estateView
                let (page, bytes, failure) = await client.estateTimeline(
                    at: base, view: view, before: query.before, span: query.span, bucket: query.bucket,
                    counter: "estate/timeline\(view == .backups ? "?view=backups" : ""):\(kind)")
                answer = page.map { .page(.estate($0), bytes: bytes) } ?? failure.map { .failed($0) } ?? .held
                return failure
            }
        }
        return answer
    }

    var semaforTimelineSource: TimelineSource {
        TimelineSource(fetch: { [weak self] query in await self?.fetchTimelinePage(query) ?? .held },
                       identity: { [weak self] host in self?.semaforServers.first { $0.host == host }?.base.absoluteString })
    }

    // MARK: - The estate, unioned (D6)

    /// Every box, each from the Semafor that observes it, in Settings order:
    /// a box two Semafors both report is drawn once, from the earlier host.
    var estateBoxes: [(host: String, box: SemaforEstateMap.Box)] {
        var seen = Set<String>()
        return semaforStates.flatMap { host, state in
            (state.map?.boxList ?? []).filter { seen.insert($0.name).inserted }.map { (host, $0) }
        }
    }

    /// The host whose Semafor reports `box`.
    func semaforHost(forBox box: String) -> String? {
        estateBoxes.first { $0.box.name == box }?.host
    }

    /// Findings and backup pipelines of the boxes `estateBoxes` draws, each
    /// from the same Semafor as its box.
    var estateFindings: [SemaforFinding] {
        let owner = Dictionary(estateBoxes.map { ($0.box.name, $0.host) }, uniquingKeysWith: { first, _ in first })
        return semaforStates.flatMap { host, state in
            (state.findings ?? []).filter { owner[$0.box] == host }
        }
    }

    var estatePipelines: [SemaforBackups.Pipeline] {
        let owner = Dictionary(estateBoxes.map { ($0.box.name, $0.host) }, uniquingKeysWith: { first, _ in first })
        return semaforStates.flatMap { host, state in
            (state.backups?.pipelineList ?? []).filter { owner[$0.box] == nil || owner[$0.box] == host }
        }
    }

    /// The oldest answer behind the estate while any of its Semafors is not
    /// answering — the views' "as of HH:MM".
    var estateAsOf: Date? {
        let down = semaforStates.filter { $0.state.unreachableSince != nil }
        guard !down.isEmpty else { return nil }
        return down.compactMap { $0.state.fetchedAt[SemaforRead.map.rawValue] }.min()
    }

    // MARK: - Snapshots

    func semaforSnapshotKey(base: URL) -> QueryKey {
        QueryKey(resource: Snapshots.semafor.name, identity: base.absoluteString)
    }

    func recordSemaforSnapshot(host: String, base: URL) {
        guard let state = semaforHosts[host] else { return }
        QueryRepository.shared.record(Snapshots.semafor, key: semaforSnapshotKey(base: base), value: state)
    }

    /// A cold start paints every host's last answer, marked unconfirmed until
    /// its Semafor answers again. `held`, not `restore`: one resource holds a
    /// key per host, and `restore` answers only the first key of a resource.
    func restoreSemafor() async {
        for (host, base) in semaforServers where semaforHosts[host] == nil {
            guard let snapshot = await QueryRepository.shared.held(Snapshots.semafor, key: semaforSnapshotKey(base: base)),
                  semaforHosts[host] == nil else { continue }
            var state = snapshot.value
            state.unreachableSince = state.unreachableSince ?? snapshot.fetchedAt
            semaforHosts[host] = state
        }
    }
}
