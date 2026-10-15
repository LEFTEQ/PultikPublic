import Foundation
import Observation

@MainActor
@Observable
final class StatusStore {
    static let shared = StatusStore()

    /// Fired after any state change the menu bar icon depends on.
    var onChange: (() -> Void)?
    var onRefreshComplete: (() -> Void)?

    var repos: [RepoStatus] = []
    var pinned: [String] {
        didSet {
            mutate { $0.pinnedRepos = pinned }
            search(searchQuery)
        }
    }

    /// Read cache for the ~30 settings this store surfaces. It is a snapshot
    /// taken at launch, so it must never be written back wholesale — see
    /// `mutate`.
    var preferences: Preferences

    /// The only way this store changes a setting: apply the change to the
    /// read cache AND to a freshly loaded file, never `preferences.save()`.
    ///
    /// Saving the cache wholesale wrote back the file as it looked at launch,
    /// silently discarding every key another store had written since — pinning
    /// a repo could undo a brightness preset or a fan-curve edit made minutes
    /// earlier, and the bigger this snapshot grew the more it could eat
    /// (docs/specs/2026-09-10-display-preset-drag-decisions.md).
    func mutate(_ change: (inout Preferences) -> Void) {
        change(&preferences)
        Preferences.update(change)
    }
    var suggestions: [String] = []
    var prodIssues: [ProdIssue] = []
    var eveSessions: [EveSession] = []
    /// eve workflows parked on an operator approval (Sessions, Now).
    var eveApprovals: [EveApproval] = []
    /// The apps shelf's latest releases (Prod's Releases section), read on
    /// entering Prod — never polled. When they were fetched: a snapshot or a
    /// failed revalidation leaves them "as of".
    var shelfReleases: [ShelfRelease] = []
    var shelfFetchedAt: Date?
    var serverMetrics: [ServerMetrics] = []
    var serviceStatuses: [ServiceStatus] = []
    /// Every alert the Prometheus and Loki rule evaluators report, fetched in
    /// the Prometheus pass; empty off-mesh or with `firing` hidden.
    /// Every write re-renders the icon: its badge counts unseen criticals,
    /// and an emptied list (off-mesh, hidden) must clear it too.
    var firingAlerts: [FiringAlert] = [] {
        didSet { if firingAlerts != oldValue { onChange?() } }
    }
    var laneBoard = CILaneBoard()
    /// Hlídač's last answer (docs/specs/2026-10-03-prod-watch-contracts.md
    /// §5), kept through an outage so a blind card still shows what it last
    /// knew. Every change re-renders the icon: its health dots read it.
    var prodDigest: HlidacDigest? {
        didSet { if prodDigest != oldValue { onChange?() } }
    }
    /// Set at the first failed fast-lane call and cleared by the next answer;
    /// while set, every prod card reads "blind since HH:MM", never green.
    var prodUnreachableSince: Date? {
        didSet { if prodUnreachableSince != oldValue { onChange?() } }
    }
    /// When the digest on screen was fetched, while it is the snapshot
    /// restored at launch and Hlídač has not answered since: the board reads
    /// "as of HH:MM", never green (copilot shell D8).
    var prodRestoredAt: Date? {
        didSet { if prodRestoredAt != oldValue { onChange?() } }
    }
    /// Deployments whose red an open panel has already shown — the menu
    /// bar's red dot stops pulsing for those (`markProdSeen`).
    var prodSeenRed: Set<String> = [] {
        didSet { if prodSeenRed != oldValue { onChange?() } }
    }
    /// settings.json problems, one orange row each: entries a lossy decode
    /// skipped, or the whole file failing while the last good copy runs.
    var configIssues: [String] = []
    var isRefreshingProd = false
    var settingsWatcher: DispatchSourceFileSystemObject?
    var settingsSeenStamp: SettingsFile.Stamp?
    /// False while settings.json does not decode cleanly: the read cache is
    /// the last good copy (or defaults), so nothing may act on its absences.
    var settingsWritable = true
    var settingsReload: Task<Void, Never>?
    /// Each host's Semafor `/overview` by the host's `ref`, refreshed at
    /// most every `throughputInterval` inside that Semafor's breaker; a host
    /// whose Semafor is not answering has none.
    var ciThroughputs: [String: CIThroughput] = [:]
    var throughputFetchedAt: [String: Date] = [:]
    static let throughputInterval: TimeInterval = 60
    /// Each host Semafor's v1 views by the host's `ref` (vt-7727 WP3), read
    /// only while a view draws them and restored from their snapshot.
    var semaforHosts: [String: SemaforHostState] = [:]
    /// CI's host chip (D6): the host whose Semafor CI shows; nil = the busiest.
    var ciHostChoice: String?
    /// A run's needs graph and critical path, read on selection, by
    /// `"<host>/<run id>"`.
    var semaforRunDetails: [String: SemaforRunDetail] = [:]
    /// A machine's per-core load and 24 h CPU, read when its detail opens
    /// (vt-7727 D9), by `ServerMetrics.id`.
    var machineHistory: [String: MachineHistory] = [:]
    var vitrinkaListening: [VitrinkaListening] { selectedVitrinkaWorkspace?.tray.listeners ?? [] }
    var vitrinkaBoards: [VitrinkaBoard] { selectedVitrinkaWorkspace?.tray.boards ?? [] }
    var vitrinkaWorkspaces: [VitrinkaWorkspaceSnapshot] = []
    var selectedVitrinkaWorkspace: VitrinkaWorkspaceSnapshot? {
        VitrinkaWorkspaceSnapshot.selected(in: vitrinkaWorkspaces, preferring: vitrinkaWorkspace,
                                           defaultWorkspace: VitrinkaClient.shared.workspace)
    }
    var eveAlerts: [EveAlert] = []
    /// ws-v2 workspaces are the Devbox surface — the widget's chips and pile,
    /// the `.devbox` page's table.
    var devboxWorkspaces: [DevboxWorkspace] = []
    var devboxSummary: DevboxOverviewSummary?
    /// When the hub payload was generated ON THE BOX — the rail's "as of"
    /// stamp. The user asked for real status; real status carries its age.
    var devboxFetchedAt: Date?
    /// Every devbox guest to poll (spec 2026-09-25) — today's single
    /// endpoint until `devbox boxes --json` first answers.
    var devboxBoxes: [DevboxEndpoint] = [.fallback]
    /// Each box's last answer; a box that fails drops out, one on hold
    /// keeps what it had — the one-box rules, per box.
    var devboxSnapshots: [String: DevboxSnapshot] = [:]
    var devboxDiscoveredAt: Date?
    var lastRefresh: Date?
    var lastSentryRefresh: Date?
    var githubPollCursor = 0
    var githubPolledAt: [String: Date] = [:]
    /// Any backend lane in flight — the footer's "Syncing".
    var isRefreshing: Bool { schedule.isRunning }
    /// One lane per backend; see `startPolling`.
    let schedule = BackendSchedule()
    var pollingStarted = false
    /// The module on screen; see `setVisibleModule`.
    @ObservationIgnored var visibleModule: PanelModule?
    /// Its view (vt-7727 D5): which Semafor reads the lane makes.
    @ObservationIgnored var visibleView: ModuleView?
    var globalError: String?

    let client = GitHubClient()
    /// The forge and the CI behind the detail card and the run card (stay in
    /// Pultík N2): GitHub today, through the one client and its budgets.
    var codeHost: any CodeHost { GitHubCodeHost(client: client) }
    var ciHost: any CIHost { GitHubCIHost(client: client) }
    /// Where `#123`, `@user` and SHAs in a description open (D8): Pultík's own
    /// detail for a change request its indexes hold, else the host's page.
    var autolinks: any AutolinkResolver { GitHubAutolinks { [weak self] in self?.indexedUpdatedAt($0) != nil } }
    var prIndex = GitHubPRIndex()
    let prIndexDisk = GitHubPRIndexDisk()
    var prIndexIdentity: String?
    var prIndexLoad: (identity: String, task: Task<GitHubPRIndex, Never>)?
    var prIndexRevision = 0
    /// The warm set (stay in Pultík D9): the `updatedAt` each change request
    /// was synced at, the diffs on disk, and the one mirror pass in flight.
    @ObservationIgnored var warmUpdatedAt: [ChangeRequestRef: Date] = [:]
    @ObservationIgnored var warmFiles: Set<String> = []
    @ObservationIgnored var warmMirrorTask: Task<Void, Never>?
    @ObservationIgnored var warmMirrorQueue: [ChangeRequest] = []
    var warmSyncedAt: Date?
    /// The CI watch (stay in Pultík D7): what it watches, our CI's last read,
    /// the last host confirm and how many there were, and per request a
    /// generation the open detail reloads on.
    var ciWatchTarget: CIWatchTarget?
    var ciLive: CIStatusSnapshot?
    @ObservationIgnored var ciConfirmedAt: Date?
    var ciConfirmReads = 0
    var ciConfirmed: [ChangeRequestRef: Int] = [:]
    /// Per request, a generation the workbench reloads on after a verb
    /// (PR workbench D4) re-read its conversation and activity.
    var prVerbRevision: [ChangeRequestRef: Int] = [:]
    var archiveCursor = 0
    var archiveAttemptedAt: Date?
    /// Circuit breaker in front of every remote host Pultík polls — including
    /// GitHub, which won't ban the machine but will happily let a broken token
    /// burn the hourly budget a hundred requests at a time.
    let gate = ProbeGate.shared
    // runId → was-running, used to notify only on observed transitions
    var previousRunning: [Int: Bool] = [:]
    var previousDeployRunning: [Int: Bool] = [:]
    /// Each box's last parked count, for the pressure-park notification.
    /// Absent until that box's first snapshot so a launch never announces
    /// history. Per box: a silent box answering again rejoins the merged
    /// total, which must never read as a park.
    var previousDevboxParked: [String: Int] = [:]
    /// Sentry issue ids already seen — notify only on genuinely new issues,
    /// and never on the first load after launch.
    var seenSentryIssues: Set<String>?
    // Eve alert ids already fetched this app run — same idiom: notify only on
    // genuinely new visible-lane alerts, first load silent. Read-state proper
    // (the unread badge) is AlertSeenStore, which persists.
    var notifiedAlertIds: Set<Int>?
    /// Critical firing-alert transitions — this app run only, first answer
    /// silent; the badge's seen-state is FiringSeenStore, which persists.
    var firingWatch = FiringWatch()

    init() {
        let snapshot = Preferences.loadSnapshot()
        let prefs = snapshot.value
        preferences = prefs
        pinned = prefs.pinnedRepos
        configIssues = snapshot.issues
        settingsWritable = snapshot.writable
        settingsSeenStamp = SettingsFile.stamp(of: Preferences.fileURL)
        Task {
            do { try await ensurePRIndex() }
            catch { NSLog("pultik: PR cache identity unavailable: %@", error.localizedDescription) }
        }
    }

    var aggregate: AggregateState {
        let failed = repos.reduce(0) { $0 + $1.failedCount }
        let running = repos.reduce(0) { $0 + $1.runningCount }
        if failed > 0 { return .failed(failed) }
        if running > 0 { return .running(running) }
        return .allClear
    }

    var anyRunning: Bool {
        repos.contains { $0.runningCount > 0 }
    }

    /// One PR of the cross-repo inbox, carrying its repo and its eve session.
    struct InboxPR: Identifiable {
        let repoSlug: String
        let info: PRInfo
        let eveSession: EveSession?
        var id: Int {
            info.id
        }

        /// "example-org/ExampleApp" → "ExampleApp"
        var repoName: String {
            repoSlug.split(separator: "/").last.map(String.init) ?? repoSlug
        }
    }

    /// The PR-first inbox: every open PR across pinned repos, eve-session
    /// attached, in FIXED repo order — `preferences.repoOrder` first, exactly
    /// as written; unlisted repos follow by recency (newest open PR); PRs
    /// within a repo newest-first. A repo's PRs are always in the same place,
    /// so the eye can go straight to them.
    var inbox: [InboxPR] {
        let sessionsByPR = Dictionary(
            eveSessions.compactMap { session in session.prKey.map { ($0, session) } },
            uniquingKeysWith: { a, b in
                (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast) ? a : b
            }
        )
        // Recency proxy for unlisted repos: the highest open-PR number —
        // GitHub has no cross-repo clock in this payload, but "which repo
        // opened work most recently" is stable and close enough.
        let newestPR = Dictionary(uniqueKeysWithValues: repos.map { repo in
            (repo.slug, repo.prs.map(\.pr.number).max() ?? 0)
        })
        func rank(_ slug: String) -> Int {
            let lower = slug.lowercased()
            return preferences.repoOrder.firstIndex { lower.contains($0.lowercased()) }
                ?? preferences.repoOrder.count
        }
        return repos
            .flatMap { repo in
                repo.prs.map { info in
                    InboxPR(
                        repoSlug: repo.slug,
                        info: info,
                        eveSession: sessionsByPR["\(repo.slug)#\(info.pr.number)".lowercased()]
                    )
                }
            }
            .sorted { a, b in
                let ra = rank(a.repoSlug), rb = rank(b.repoSlug)
                if ra != rb { return ra < rb }
                if a.repoSlug != b.repoSlug {
                    let na = newestPR[a.repoSlug] ?? 0, nb = newestPR[b.repoSlug] ?? 0
                    if na != nb { return na > nb }
                    return a.repoSlug < b.repoSlug
                }
                return a.info.pr.number > b.info.pr.number
            }
    }

    // MARK: - Search state (its code: Backends/StatusStore+Search.swift)

    var searchResults: [ArchivedPR] = []
    var isSearching = false
    var searchError: String?
    var searchFetchedAt: Date?
    var searchIsPartial = false
    var localSearchMilliseconds: Double = 0
    var searchTask: Task<Void, Never>?
    var searchQuery = ""
    var searchScope = ""

    var sentryResults: [ProdIssue] = []
    var isSearchingSentry = false
    var sentrySearchTask: Task<Void, Never>?
    var sentryQuery = ""

    /// The mode's resting list: most recently touched issues across the same
    /// repos, kept warm by the poll loop so `.issues` opens with something to
    /// scan instead of an empty box.
    var recentIssues: [ArchivedIssue] = []
    var isPrefetchingIssues = false
    var lastIssueRefresh: Date?

    var issueResults: [ArchivedIssue] = []
    var isSearchingIssues = false
    var issueSearchError: String?
    var issueSearchTask: Task<Void, Never>?
    var issueQuery = ""
    /// Session-lifetime LRU of query → hits: backspacing through a query, or
    /// re-running one, redraws instead of re-hitting GitHub. A few minutes of
    /// staleness is irrelevant on an archive.
    var issueCache: [String: [ArchivedIssue]] = [:]
    var issueCacheOrder: [String] = []

    #if DEBUG
    /// `tools/panel-drive.sh firing …`: made-up alerts appended to every
    /// answered fetch until cleared, so notifications, the badge and the
    /// rail can be exercised without a real rule firing.
    var debugFiring: [FiringAlert] = []
    #endif

    // MARK: - Polling

    /// One lane per backend (`BackendSchedule`, copilot shell D8), each on its
    /// own clock behind its own breaker: a slow GitHub fan-out never holds
    /// back vitrinka or devbox, and prod keeps its 15 s fast lane (decision
    /// log: one request, every 15 s). A cold start first restores every
    /// backend's last snapshot, so the panel is never blank.
    func startPolling() {
        guard !pollingStarted else { return }
        pollingStarted = true
        startWatchingSettings()
        schedule.onLaneComplete = { [weak self] in self?.onRefreshComplete?() }
        let cadence: @MainActor () -> TimeInterval = { [weak self] in (self?.anyRunning ?? false) ? 30 : 90 }
        // N1: a visible module's refresh speed tightens its backends' lanes.
        func lane(_ name: String) -> @MainActor () -> TimeInterval {
            { [weak self] in min(cadence(), self?.visibleCadence(name) ?? .infinity) }
        }
        schedule.add("prod", every: { [weak self] in min(15, self?.visibleCadence("prod") ?? 15) }) { [weak self] in
            await self?.refreshProd()
            // One stat: the directory watch misses in-place writes (an
            // editor that truncates and rewrites keeps the inode).
            self?.settingsDirectoryChanged()
        }
        schedule.add("github", every: lane("github")) { [weak self] in await self?.refreshGitHubLane() }
        schedule.add("eve", every: lane("eve")) { [weak self] in await self?.refreshEve() }
        schedule.add("infra", every: lane("infra")) { [weak self] in await self?.refreshInfraMetrics() }
        schedule.add("vitrinka", every: lane("vitrinka")) { [weak self] in await self?.refreshVitrinka() }
        schedule.add("devbox", every: lane("devbox")) { [weak self] in await self?.refreshDevbox() }
        // Only while a view draws it: nothing reads Semafor while hidden (D10).
        schedule.add("semafor", every: { [weak self] in self?.semaforInterval(cadence: cadence()) ?? 3600 }) { [weak self] in
            await self?.refreshSemafor()
        }
        // Both keep their own five-minute floors inside.
        schedule.add("sentry", every: cadence) { [weak self] in await self?.refreshSentryIfStale() }
        schedule.add("issues", every: cadence) { [weak self] in await self?.refreshIssuesIfStale() }
        Task {
            await restoreSnapshots()
            schedule.start()
        }
    }

    /// The module on screen (nil while the panel is hidden): its backends
    /// refresh at its Settings ▸ Modules speed (stay in Pultík N1).
    /// A view of its own (vt-7727 D5) decides which Semafor reads the lane
    /// makes; a change to what is on screen reads what it needs now.
    func setVisibleModule(_ module: PanelModule?, view: ModuleView? = nil) {
        guard module != visibleModule || view != visibleView else { return }
        let before = Self.lanes.map(visibleCadence)
        visibleModule = module
        visibleView = view
        if Self.lanes.map(visibleCadence) != before { schedule.nudge() }
        if module != nil { kickSemafor() }
    }

    static let lanes = ["prod", "github", "eve", "infra", "vitrinka", "devbox"]
    /// The lanes a module draws from.
    static let moduleLanes: [PanelModule: Set<String>] = [
        .home: ["prod", "github", "eve", "infra", "vitrinka", "devbox", "semafor"],
        .prs: ["github"], .ci: ["github", "infra", "semafor"], .prod: ["prod"], .devbox: ["devbox"],
        .work: ["vitrinka"], .sessions: ["eve", "vitrinka"], .estate: ["infra", "semafor"],
    ]
    /// GitHub-backed modules never poll it faster than this: the hourly
    /// request budget is shared with every other GitHub read.
    static let githubFloor: TimeInterval = 30

    /// `lane`'s cadence while the visible module draws from it; nil = the
    /// shared one.
    func visibleCadence(_ lane: String) -> TimeInterval? {
        guard let module = visibleModule, Self.moduleLanes[module]?.contains(lane) == true,
              let interval = moduleSettings.first(where: { $0.module == module })?.visibleRefresh.interval
        else { return nil }
        return lane == "github" ? max(interval, Self.githubFloor) : interval
    }

    /// Runs a remote subsystem's fetch unless its breaker is open.
    ///
    /// Everything Pultík polls lives behind one of these. `work` returns the
    /// failure that made it come back empty, or nil; on a half-open `trial`
    /// only the single cheap `probe` request goes out, and the fan-out waits
    /// for it to prove the host is answering again. The probe returns the
    /// CLASSIFIED failure (or nil for success) — a 403 seen on a trial must
    /// re-arm the pause as `.rejected`, not be flattened to "not answering".
    func gated(
        _ target: ProbeTarget,
        probe: () async -> ProbeFailure? = { nil },
        work: () async -> ProbeFailure?
    ) async {
        switch gate.verdict(target) {
        case .hold:
            return
        case .trial:
            if let failure = await probe() {
                gate.failed(target, failure)
                return
            }
            gate.succeeded(target)
        case .go:
            break
        }
        if let failure = await work() {
            gate.failed(target, failure)
        } else {
            gate.succeeded(target)
        }
    }

    /// Refresh unless one just happened.
    ///
    /// Opening the panel refreshes, and the panel is a ⌥Space away — without a
    /// floor, toggling it a dozen times fires a dozen full fan-outs (over a
    /// thousand GitHub requests) for data that cannot have changed. The footer
    /// button and every explicit action still call `refresh()` directly.
    func refreshIfStale(minimumInterval: TimeInterval = 15) async {
        // Each lane's last ATTEMPT, deliberately not `lastRefresh`: that one
        // tracks when the inbox data last changed hands and stops advancing
        // while GitHub is paused, which would quietly re-open the floodgate
        // for every other subsystem.
        await schedule.runStale(olderThan: minimumInterval)
    }

    /// Every lane now — the footer's button and explicit actions. A lane
    /// already in flight is joined, never doubled.
    func refresh() async {
        await schedule.runAll()
    }
}
