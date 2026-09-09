import Foundation

// MARK: - GitHub API payloads (decoded with .convertFromSnakeCase + .iso8601)

struct WorkflowRunsResponse: Decodable {
    let workflowRuns: [WorkflowRun]
}

struct WorkflowRun: Decodable, Identifiable {
    let id: Int
    let name: String?
    let headBranch: String?
    let status: String // queued | in_progress | completed | waiting | pending
    let conclusion: String? // success | failure | cancelled | timed_out | ...
    let htmlUrl: String
    let createdAt: Date
    let updatedAt: Date

    var isRunning: Bool {
        status != "completed"
    }

    var failed: Bool {
        ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "")
    }
}

struct Deployment: Decodable, Identifiable {
    let id: Int
    let environment: String
    let ref: String
    let createdAt: Date
}

struct DeploymentStatus: Decodable {
    let state: String // pending | queued | in_progress | success | failure | error | inactive
    let targetUrl: String?
    let environmentUrl: String?
}

struct PullRequest: Decodable, Identifiable {
    let id: Int
    let number: Int
    let title: String
    let htmlUrl: String
    let draft: Bool?
    let head: Head

    struct Head: Decodable {
        let sha: String
        let ref: String
    }
}

struct PRReview: Decodable {
    let state: String // APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED | PENDING
    let user: User?

    struct User: Decodable {
        let login: String
    }
}

struct CheckRunsResponse: Decodable {
    let checkRuns: [CheckRun]
}

struct CheckRun: Decodable {
    let status: String // queued | in_progress | completed
    let conclusion: String?
}

struct DiscoveredRepo: Decodable {
    let fullName: String
}

// MARK: - PR search (the archive: closed & merged, on demand)

struct PRSearchResponse: Decodable {
    let items: [PRSearchItem]
}

/// One /search/issues hit, restricted to `is:pr`.
struct PRSearchItem: Decodable {
    let number: Int
    let title: String
    let htmlUrl: String
    let state: String // open | closed
    let draft: Bool?
    let repositoryUrl: String // https://api.github.com/repos/example-org/ExampleApp
    let updatedAt: Date
    let pullRequest: Ref?

    struct Ref: Decodable {
        let mergedAt: Date?
    }
}

/// /repos/{repo}/pulls/{number} — the exact-number path, because full-text
/// search cannot answer "the PR whose number is 520".
struct PRLookup: Decodable {
    let number: Int
    let title: String
    let htmlUrl: String
    let state: String
    let draft: Bool?
    let mergedAt: Date?
    let updatedAt: Date
}

enum PROutcome {
    case merged, closed, open, draft
}

/// A PR found by searching GitHub — any state, any active repo, pinned or not.
/// Deliberately thinner than `PRInfo`: history needs no checks or reviews.
struct ArchivedPR: Identifiable {
    let repoSlug: String
    let number: Int
    let title: String
    let url: String
    let outcome: PROutcome
    let updatedAt: Date

    var id: String {
        "\(repoSlug)#\(number)"
    }

    /// "example-org/ExampleApp" → "ExampleApp"
    var repoName: String {
        repoSlug.split(separator: "/").last.map(String.init) ?? repoSlug
    }

    init(item: PRSearchItem) {
        repoSlug = ArchivedPR.slug(fromApiUrl: item.repositoryUrl)
        number = item.number
        title = item.title
        url = item.htmlUrl
        outcome = ArchivedPR.outcome(
            state: item.state, mergedAt: item.pullRequest?.mergedAt, draft: item.draft
        )
        updatedAt = item.updatedAt
    }

    init(lookup: PRLookup, repoSlug: String) {
        // A renamed repo answers under its old slug via a 301, so trust the
        // URL we came back with over the one we asked for.
        self.repoSlug = ArchivedPR.slug(fromHtmlUrl: lookup.htmlUrl) ?? repoSlug
        number = lookup.number
        title = lookup.title
        url = lookup.htmlUrl
        outcome = ArchivedPR.outcome(
            state: lookup.state, mergedAt: lookup.mergedAt, draft: lookup.draft
        )
        updatedAt = lookup.updatedAt
    }

    /// A merged PR is `state: "closed"` too — merged_at is the only tell.
    private static func outcome(state: String, mergedAt: Date?, draft: Bool?) -> PROutcome {
        if mergedAt != nil { return .merged }
        if state == "closed" { return .closed }
        return draft == true ? .draft : .open
    }

    /// "https://api.github.com/repos/example-org/ExampleApp" → "example-org/ExampleApp"
    private static func slug(fromApiUrl url: String) -> String {
        let parts = url.split(separator: "/")
        guard parts.count >= 2 else { return url }
        return parts.suffix(2).joined(separator: "/")
    }

    /// "https://github.com/example-org/ExampleApp/pull/520" → "example-org/ExampleApp"
    private static func slug(fromHtmlUrl url: String) -> String? {
        let parts = url.split(separator: "/")
        guard let pull = parts.firstIndex(of: "pull"), pull >= 2 else { return nil }
        return parts[(pull - 2) ..< pull].joined(separator: "/")
    }
}

// MARK: - Issue search (the .issues mode)

/// Present on an issues-endpoint payload ONLY when the hit is really a pull
/// request. Issues and PRs share one number sequence and one endpoint family,
/// so this key is the single reliable tell.
struct PullRequestMarker: Decodable {}

struct IssueSearchResponse: Decodable {
    let items: [IssueSearchItem]
}

/// One /search/issues hit under `is:issue`, carrying the fields a PR row never
/// needed: labels, comment count, and why it was closed.
struct IssueSearchItem: Decodable {
    let number: Int
    let title: String
    let htmlUrl: String
    let state: String // open | closed
    let stateReason: String? // completed | not_planned | reopened
    let repositoryUrl: String // https://api.github.com/repos/example-org/ExampleApp
    let comments: Int
    let labels: [IssueLabel]
    let updatedAt: Date
    let pullRequest: PullRequestMarker?
}

/// /repos/{repo}/issues/{number} — the exact-number path. It answers for PRs
/// too, which is why `pullRequest` is decoded here as well.
struct IssueLookup: Decodable {
    let number: Int
    let title: String
    let htmlUrl: String
    let state: String
    let stateReason: String?
    let comments: Int
    let labels: [IssueLabel]
    let updatedAt: Date
    let pullRequest: PullRequestMarker?
}

struct IssueLabel: Decodable {
    let name: String
}

enum IssueOutcome {
    case open, closed, notPlanned
}

/// An issue found by searching GitHub — any state, any active repo. Sibling to
/// `ArchivedPR` rather than a variant of it: the PR path has no use for labels
/// or comment counts, and this one has no use for merge state.
struct ArchivedIssue: Identifiable {
    let repoSlug: String
    let number: Int
    let title: String
    let url: String
    let outcome: IssueOutcome
    let labels: [String]
    let comments: Int
    let updatedAt: Date

    var id: String {
        "\(repoSlug)#\(number)"
    }

    /// "example-org/ExampleApp" → "ExampleApp"
    var repoName: String {
        repoSlug.split(separator: "/").last.map(String.init) ?? repoSlug
    }

    /// Search hits that are really PRs are dropped — `is:issue` should have
    /// excluded them, but the endpoint is shared and the key is cheap to check.
    init?(item: IssueSearchItem) {
        guard item.pullRequest == nil else { return nil }
        repoSlug = ArchivedIssue.slug(fromApiUrl: item.repositoryUrl)
        number = item.number
        title = item.title
        url = item.htmlUrl
        outcome = ArchivedIssue.outcome(state: item.state, reason: item.stateReason)
        labels = item.labels.map(\.name)
        comments = item.comments
        updatedAt = item.updatedAt
    }

    init?(lookup: IssueLookup, repoSlug: String) {
        guard lookup.pullRequest == nil else { return nil } // #812 is a PR here
        // A renamed repo answers under its old slug via a 301, so trust the
        // URL we came back with over the one we asked for.
        self.repoSlug = ArchivedIssue.slug(fromHtmlUrl: lookup.htmlUrl) ?? repoSlug
        number = lookup.number
        title = lookup.title
        url = lookup.htmlUrl
        outcome = ArchivedIssue.outcome(state: lookup.state, reason: lookup.stateReason)
        labels = lookup.labels.map(\.name)
        comments = lookup.comments
        updatedAt = lookup.updatedAt
    }

    /// "not_planned" is worth its own tone — it closed because it was never
    /// real, which reads differently from closed-because-fixed.
    private static func outcome(state: String, reason: String?) -> IssueOutcome {
        guard state == "closed" else { return .open }
        return reason == "not_planned" ? .notPlanned : .closed
    }

    /// "https://api.github.com/repos/example-org/ExampleApp" → "example-org/ExampleApp"
    private static func slug(fromApiUrl url: String) -> String {
        let parts = url.split(separator: "/")
        guard parts.count >= 2 else { return url }
        return parts.suffix(2).joined(separator: "/")
    }

    /// "https://github.com/example-org/ExampleApp/issues/812" → "example-org/ExampleApp"
    private static func slug(fromHtmlUrl url: String) -> String? {
        let parts = url.split(separator: "/")
        guard let issues = parts.firstIndex(of: "issues"), issues >= 2 else { return nil }
        return parts[(issues - 2) ..< issues].joined(separator: "/")
    }
}

// MARK: - Sentry (self-hosted, mesh)

struct SentryIssue: Decodable, Identifiable {
    let id: String
    let shortId: String
    let title: String
    let culprit: String?
    let count: String // Sentry serializes event counts as strings
    let userCount: Int
    let level: String // error | fatal | warning | ...
    let permalink: String
    let lastSeen: Date
    /// The owning project — org-level search hits span projects, and the
    /// palette needs the slug to label them ("ExampleApp"). Optional because it is
    /// irrelevant on project-scoped fetches, where the request already knows.
    let project: ProjectRef?

    struct ProjectRef: Decodable {
        let slug: String
    }

    var eventCount: Int {
        Int(count) ?? 0
    }
}

/// A Sentry issue tagged with the project it came from.
struct ProdIssue: Identifiable {
    let project: String // "exampleapp-api"
    let issue: SentryIssue
    var id: String {
        issue.id
    }

    /// "exampleapp-api" → "ExampleApp", "booking-back" → "Booking"
    var productLabel: String {
        project.hasPrefix("exampleapp") ? "ExampleApp" : project.hasPrefix("booking") ? "Booking" : project
    }
}

// MARK: - Infra metrics (mesh Prometheus)

/// One VPS's node-exporter snapshot, percentages 0–100.
struct ServerMetrics: Identifiable {
    let name: String // "BuildServer"
    let instance: String // prometheus instance label, e.g. "build-vps"
    var cpu: Double?
    var ram: Double?
    var disk: Double?
    /// Absolute sizes behind the percentages — the footer says "18/32 GB".
    var ramUsedBytes: Double?
    var ramTotalBytes: Double?
    var diskUsedBytes: Double?
    var diskTotalBytes: Double?
    var id: String {
        instance
    }

    var worst: Double {
        max(cpu ?? 0, ram ?? 0, disk ?? 0)
    }
}

/// Load pressure, the only thing the footer meters need to decide a colour.
/// Thresholds are the operator's: fine until three quarters, loud past nine
/// tenths — the point where a box stops absorbing a surprise.
enum LoadTier {
    case calm, warm, hot

    init(percent: Double) {
        switch percent {
        case ..<75: self = .calm
        case ..<90: self = .warm
        default: self = .hot
        }
    }
}

/// "18/32 GB", "1.8/3.5 TB" — the pair is scaled by the TOTAL so both halves
/// share a unit, and BuildServer's 3.5 TB disk doesn't render as 3576 GB.
func formatSize(used: Double, total: Double) -> String {
    let gb = 1_073_741_824.0
    let terabytes = total >= 1000 * gb
    let divisor = terabytes ? gb * 1024 : gb
    let unit = terabytes ? "TB" : "GB"
    let scaledTotal = total / divisor
    let digits = scaledTotal < 10 ? 1 : 0
    let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits))
    return "\((used / divisor).formatted(format))/\(scaledTotal.formatted(format)) \(unit)"
}

/// One service's blackbox probe snapshot.
struct ServiceStatus: Identifiable {
    let name: String // "exampleapp-prod"
    let probe: String // probe instance label (URL)
    /// The `servers[].name` of the box this service runs on — the rail's group
    /// key. Nil means unfiled, not unknown-host: the rail shows those last
    /// under their own heading rather than dropping them.
    var host: String?
    var up: Bool?
    var latencySeconds: Double?
    var id: String {
        probe
    }

    var latencyLabel: String {
        guard let latencySeconds else { return "—" }
        return latencySeconds < 1 ? "\(Int(latencySeconds * 1000))ms"
            : String(format: "%.1fs", latencySeconds)
    }
}

/// One JIT lane in the BuildServer fleet — a `ci-kvm-controller@<lane>`
/// instance (`ci_kvm_controller_up`). Runners are per-job, ephemeral and
/// nameless since 2026-08-30, so the lane is the stable unit and its running
/// jobs are the occupancy (spec 2026-09-09).
struct CILane: Identifiable {
    let name: String // "exampleapp-ci"
    let backend: String // "docker" | "kvm"
    let trustGroup: String // "firefly" (CI) | "bastion" (deploys)
    let up: Bool // controller unit active
    let maxRunners: Int? // `ci_lane_info`; nil until the infra side exports it
    let queued: Int
    let jobs: [CIJob]

    var id: String { name }
    var running: Int { jobs.count }
    /// Worth a row of its own: busy, backed up, or broken. Everything else
    /// folds into the section's "N idle" line.
    var isActive: Bool { !jobs.isEmpty || queued > 0 || !up }
}

/// A job executing on the fleet right now (`ci_runner_job_info`, one series
/// per running job, link included — no GitHub lookup needed).
struct CIJob: Identifiable {
    let org: String
    let repo: String // "ExampleApp"
    let lane: String
    let workflow: String
    let jobName: String
    let runURL: URL?
    let since: Date?

    var id: String {
        runURL?.absoluteString ?? "\(org)/\(repo)/\(workflow)/\(jobName)/\(since?.timeIntervalSince1970 ?? 0)"
    }
}

/// The whole CI picture for one poll: every enabled lane plus the jobs the
/// collector saw on lanes that are not ours (`github-hosted`, `unknown`).
struct CILaneBoard {
    var lanes: [CILane] = []
    var elsewhere: [CIJob] = []
    var elsewhereQueued: Int = 0

    var isEmpty: Bool { lanes.isEmpty }
    var running: Int { lanes.reduce(0) { $0 + $1.running } }
}

// MARK: - Project registry (the on-call layer)

struct ProjectSpec: Codable, Identifiable {
    var key: String // palette match: "exampleapp"
    var title: String // "ExampleApp"
    var repos: [String] = [] // "example-org/ExampleApp" — matches pinned slugs
    var sentryProjects: [String] = []
    var services: [String] = [] // ServiceStatus.name references
    var links: [Link] = []
    var id: String {
        key
    }

    struct Link: Codable, Identifiable {
        var title: String
        var url: String
        var id: String {
            url
        }
    }
}

// MARK: - Eve PR-subagent sessions

struct EveSessionsResponse: Decodable {
    let sessions: [EveSession]
}

struct EveSession: Decodable, Identifiable {
    let id: String
    let status: String? // running | completed | failed | waiting
    let updatedAt: Date?
    let source: Source?
    let prompt: String?

    struct Source: Decodable {
        let repo: String?
        let prNumber: Int?
    }

    var isRunning: Bool {
        status == "running"
    }

    /// PR identity: source metadata when present, else parsed from the
    /// subagent prompt ("Repo: example-org/ExampleApp\nNumber: 641").
    var prKey: String? {
        if let repo = source?.repo, let number = source?.prNumber {
            return "\(repo)#\(number)".lowercased()
        }
        guard let prompt,
              let repoRange = prompt.range(of: #"Repo: (\S+)"#, options: .regularExpression),
              let numberRange = prompt.range(of: #"Number: (\d+)"#, options: .regularExpression)
        else { return nil }
        let repo = prompt[repoRange].dropFirst("Repo: ".count)
        let number = prompt[numberRange].dropFirst("Number: ".count)
        return "\(repo)#\(number)".lowercased()
    }

    var consoleUrl: String {
        "https://eve.ops.example.invalid/sessions/\(id)"
    }
}

// MARK: - Eve alerts (notifications ledger)

struct EveAlertsResponse: Decodable {
    let notifications: [EveAlert]
}

/// One eve notification — what lands in the Telegram forum topics, mirrored
/// into the Postgres ledger at the `sendFlowTelegram` chokepoint.
struct EveAlert: Decodable, Identifiable {
    let id: Int
    let ts: Date
    let flow: String // "monitor", "exampleapp_prod", …
    let category: String // lane: "incidents", "priority", …
    let severity: Severity? // null when the emitter doesn't know
    let title: String
    let body: String

    enum Severity: String, Decodable {
        case critical, warning
    }
}

// MARK: - Aggregated view models

enum CheckState {
    case running, success, failure, none
}

struct DeployInfo: Identifiable {
    let deployment: Deployment
    let state: String
    let url: String?
    var id: Int {
        deployment.id
    }

    var isRunning: Bool {
        ["pending", "queued", "in_progress"].contains(state)
    }

    var failed: Bool {
        state == "failure" || state == "error"
    }
}

enum ReviewState {
    case approved, changesRequested, awaiting
}

struct PRInfo: Identifiable {
    let pr: PullRequest
    let state: CheckState
    let review: ReviewState
    var id: Int {
        pr.id
    }

    var isDraft: Bool {
        pr.draft ?? false
    }

    /// Attention-first ordering: needs-me < awaiting < ready < draft.
    var attentionRank: Int {
        if isDraft { return 3 }
        if state == .failure || review == .changesRequested { return 0 }
        if review == .awaiting || state == .running { return 1 }
        return 2
    }
}

struct RepoStatus: Identifiable {
    let slug: String // "owner/name"
    var runs: [WorkflowRun] = []
    var deploys: [DeployInfo] = []
    var prs: [PRInfo] = []
    var error: String?
    var id: String {
        slug
    }

    var runningCount: Int {
        runs.filter(\.isRunning).count
            + deploys.filter(\.isRunning).count
            + prs.filter { $0.state == .running }.count
    }

    var failedCount: Int {
        runs.filter(\.failed).count
            + deploys.filter(\.failed).count
            + prs.filter { $0.state == .failure }.count
    }
}

enum AggregateState: Equatable {
    case allClear
    case running(Int)
    case failed(Int)
}

// MARK: - Devbox (ws-v2 workspaces on BuildServer)

/// One checkout inside a slot. Branch state comes from `devbox status --json`;
/// cadvisor has no idea what a git repo is.
struct DevboxRepo: Identifiable, Codable {
    let name: String
    let branch: String
    let dirty: Int
    let ahead: Int
    let behind: Int
    var id: String {
        name
    }

    var isClean: Bool {
        dirty == 0 && ahead == 0 && behind == 0
    }
}

/// One container of a slot's stack, from `devbox hub --json`'s docker
/// ps + stats pass — the drill-down rows behind a slot's totals.
struct DevboxContainerStat: Identifiable, Codable {
    let name: String
    /// docker's sum-of-cores number (100 = one core busy).
    let cpuPercent: Double
    let memBytes: Double
    /// docker ps prose ("Up 3 hours (healthy)", "Exited (1) 2 hours ago").
    let status: String
    var id: String {
        name
    }

    var isUp: Bool {
        status.hasPrefix("Up")
    }

    /// "(healthy)" / "(unhealthy)" when the container declares a healthcheck.
    var isUnhealthy: Bool {
        status.contains("(unhealthy)")
    }

    var memoryLabel: String {
        guard memBytes > 0 else { return "—" }
        let gb = memBytes / 1_073_741_824
        if gb >= 1 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fM", memBytes / 1_048_576)
    }
}

/// One routed workspace surface (`portal.example-studio.ws.example.invalid`), from
/// the vhosts deployed on the box. `up` is live — something listens on the
/// upstream port. Resolvable everywhere, reachable only on the mesh.
struct DevboxHost: Identifiable, Codable {
    let workspace: String
    let fqdn: String
    let port: Int
    let up: Bool
    var id: String {
        fqdn
    }

    /// "portal" from "portal.example-studio.ws.example.invalid" — the chip label.
    var label: String {
        String(fqdn.split(separator: ".").first ?? "app")
    }

    /// The open target — VALIDATED, same philosophy as `DevboxName`: the
    /// fqdn arrives in a remote payload and ends up in NSWorkspace.open, so
    /// it must be a plain hostname under the ws domain. The charset check
    /// matters as much as the suffix: "evil.example/x.ws.example.invalid" passes
    /// a suffix test but opens evil.example. Fails → nil, chip goes inert.
    var url: URL? {
        guard fqdn.hasSuffix(".ws.example.invalid"),
              fqdn.count <= 253,
              fqdn.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil
        else { return nil }
        return URL(string: "http://\(fqdn)")
    }
}

/// One process exposed by a ws-v2 workspace. Its runtime state comes from the
/// box, while port/FQDN/source are enriched by this Mac's `devbox ws ls`.
struct DevboxWorkspaceApp: Identifiable {
    let name: String
    let port: Int?
    let fqdn: String?
    let syncPath: String?
    /// systemd ActiveState (active/inactive/failed/…), nil when the unit is
    /// not installed or the box returned an older payload.
    let active: String?
    /// Public-vhost liveness from hub's one `ss` pass. Hostless instance apps
    /// deliberately have no equivalent probe; their unit state is the truth.
    let hostUp: Bool?
    /// The box's own answer for "where does this app listen" — the same
    /// string `devbox url` prints. Empty for source-only apps. VALIDATED
    /// before use: it arrives over the network and ends in NSWorkspace.open.
    var remoteURL: String? = nil

    var id: String {
        name
    }

    var isActive: Bool {
        active == "active"
    }

    var isFailed: Bool {
        active == "failed"
    }

    /// Committed workspaces prefer their routed domain. Hostless instances
    /// are reached directly over the mesh, by design. The box's `url` wins
    /// when it validates; the port-derived address stays as the fallback for
    /// an older payload, so the two can never disagree about the mesh IP.
    var url: URL? {
        if let remote = Self.meshURL(remoteURL) { return remote }
        if let fqdn, !fqdn.isEmpty {
            guard fqdn.hasSuffix(".ws.example.invalid"),
                  fqdn.count <= 253,
                  fqdn.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$",
                             options: .regularExpression) != nil
            else { return nil }
            return URL(string: "http://\(fqdn)")
        }
        guard let port, (1 ... 65535).contains(port) else { return nil }
        return URL(string: "http://192.0.2.10:\(port)")
    }

    /// Accepts exactly `http://192.0.2.10:<port>` (optionally with a bare `/`)
    /// and nothing else — no other host, no path, no query, no credentials.
    /// `*.ws.example.invalid` names are never synthesized from this field; they
    /// belong to committed workspaces and arrive as `fqdn`.
    static func meshURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, raw.count <= 64,
              let parts = URLComponents(string: raw),
              parts.scheme == "http",
              parts.host == "192.0.2.10",
              let port = parts.port, (1 ... 65535).contains(port),
              parts.path.isEmpty || parts.path == "/",
              parts.query == nil, parts.fragment == nil,
              parts.user == nil, parts.password == nil
        else { return nil }
        return URL(string: "http://192.0.2.10:\(port)")
    }
}

/// A distinct local checkout feeding a workspace. Multi-repo committed
/// workspaces can carry several; per-branch recipe instances normally carry
/// one worktree shared by all their app processes.
struct DevboxWorkspaceSource: Identifiable {
    let app: String
    let path: String
    var id: String {
        path
    }
}

/// The ws-v2 unit of work. This is deliberately assembled from several
/// partial truths: `.ws-meta` (identity), systemd (runtime), local manifests
/// (apps/ports/source), hub vhosts (public URLs), and exact compose projects
/// (fleet metrics). No one source covers both committed and per-branch forms.
struct DevboxWorkspace: Identifiable {
    let name: String
    let project: String?
    let branch: String?
    let portBase: Int?
    var portCount: Int? = nil
    let created: Date?
    let apps: [DevboxWorkspaceApp]
    let stats: [DevboxContainerStat]
    let memoryBytes: Double
    let cpuPercent: Double
    let declaredSources: [DevboxWorkspaceSource]
    /// `running` | `parked` from the overview (2026-09-02 parking contract).
    /// A parked workspace keeps its identity and is one `devbox up`
    /// from hot; it never counts in capacity.running.
    var state: String = "running"
    /// `devbox hold` — exempt from the park sweep until `unhold`.
    var hold: Bool = false
    var parkedAt: Date? = nil
    /// The worktree on this Mac that `devbox up` syncs from. Only this path
    /// can revive the workspace — `up` resolves its recipe from the cwd.
    var macPath: String? = nil
    /// Recipe `resources.memory` in GiB; nil when the recipe is silent.
    var declaredGB: Int? = nil
    /// Slice MemoryPeak (systemd ≥ 254), or the peak recorded at the last
    /// park — the learned footprint admission uses when the recipe is silent.
    var memPeakBytes: Double = 0
    /// The box's `WS_MEM_ESTIMATE_DRIFT` verdict text, when declared and
    /// measured disagree; nil otherwise.
    var drift: String? = nil

    var id: String {
        name
    }

    var isParked: Bool {
        state == "parked"
    }

    /// The box says the target is up. Distinct from `isRunning`, which is
    /// about units answering — a hot workspace whose units all died is still
    /// a hot slot and must stay on the rail, just not green.
    var isHot: Bool {
        state == "running"
    }

    var unitApps: [DevboxWorkspaceApp] {
        apps.filter { $0.active != nil }
    }

    var activeApps: Int {
        unitApps.filter(\.isActive).count
    }

    var failedApps: Int {
        unitApps.filter(\.isFailed).count
    }

    var isRunning: Bool {
        activeApps > 0 || apps.contains { $0.hostUp == true } || stats.contains(where: \.isUp)
    }

    var memoryLabel: String {
        Self.gigabytes(memoryBytes)
    }

    var memPeakLabel: String {
        Self.gigabytes(memPeakBytes)
    }

    /// "2.7G · peak 5.5G" — live use next to the learned footprint. A parked
    /// workspace has no live figure, only what it peaked at before parking.
    var footprintLabel: String? {
        guard memoryBytes > 0 || memPeakBytes > 0 else { return nil }
        var parts = [String]()
        if !isParked, memoryBytes > 0 { parts.append(memoryLabel) }
        if memPeakBytes > 0 { parts.append("peak \(memPeakLabel)") }
        return parts.joined(separator: " · ")
    }

    /// Tooltip for the footprint: the declaration (or its absence) and the
    /// box's drift verdict verbatim — never re-derived here.
    var footprintHelp: String {
        var lines = [String]()
        if let declaredGB {
            lines.append("declared \(declaredGB)G (recipe resources.memory)")
        } else {
            lines.append("no declaration — admission uses the learned peak, else 3G")
        }
        if memPeakBytes > 0 { lines.append("peak \(memPeakLabel)") }
        if let drift, !drift.isEmpty { lines.append(drift) }
        return lines.joined(separator: "\n")
    }

    /// "parked · 3h" — how long the slot has been cold.
    var parkedLabel: String {
        guard let parkedAt else { return "parked" }
        return "parked · \(Self.age(since: parkedAt))"
    }

    var cpuLabel: String {
        guard !stats.isEmpty else { return "—" }
        return "\(Int(cpuPercent.rounded()))%"
    }

    /// "24M" / "2.7G" / "12G" — a 24 MB idle slice must not print as 0.0G.
    static func gigabytes(_ bytes: Double) -> String {
        guard bytes > 0 else { return "—" }
        let gb = bytes / 1_073_741_824
        if gb < 1 { return String(format: "%.0fM", bytes / 1_048_576) }
        return gb >= 10 ? String(format: "%.0fG", gb) : String(format: "%.1fG", gb)
    }

    /// Compact relative age: "40s", "12m", "3h", "2d".
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }

    var portWindowLabel: String? {
        let width = portCount ?? 20 // Older guests allocated fixed 20-port windows.
        guard let portBase, (1 ... 65535).contains(portBase),
              width > 0, width <= 65536 - portBase else { return nil }
        return width == 1 ? "\(portBase)" : "\(portBase)–\(portBase + width - 1)"
    }

    var sources: [DevboxWorkspaceSource] {
        var seen = Set<String>()
        var result = [DevboxWorkspaceSource]()
        for source in declaredSources where !source.path.isEmpty && seen.insert(source.path).inserted {
            result.append(source)
        }
        for app in apps {
            guard let path = app.syncPath, !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(DevboxWorkspaceSource(app: app.name, path: path))
        }
        return result
    }
}

/// Optional nested fields preserve older overview documents whose identities
/// block only carried used/capacity. Saved identities and live port leases are
/// separate facts in the dynamic producer.
struct DevboxOverviewIdentities: Codable {
    let saved: Int?
    let runtimeLeases: Int?
    let portsUsed: Int?
    let portCapacity: Int?
}

/// Pure decoding model shared by the SSH client and focused compatibility tests.
struct DevboxOverviewCapacity: Codable {
    let identitySlots: Int
    let targetHot: Int
    let hotCeiling: Int?
    let claimed: Int
    let running: Int
    let identities: DevboxOverviewIdentities?
    let parked: Int?
    let floorGB: Int?
    let pressureSome: Double?
    let pressureFull: Double?
}

/// The overview's capacity + resources block. Modern guests admit by RAM;
/// hotCeiling is retained for older payloads. floorGB is the protected
/// MemAvailable line the park sweep defends.
struct DevboxOverviewSummary {
    let identitySlots: Int
    let targetHot: Int
    let hotCeiling: Int
    let claimed: Int
    let running: Int
    let identities: DevboxOverviewIdentities?
    let parked: Int
    let floorGB: Int
    /// Memory PSI avg10, the same readings the sweep and admission act on.
    let pressureSome: Double
    let pressureFull: Double
    let cpus: Int
    let load1: Double
    let memoryTotalBytes: Double
    let memoryAvailableBytes: Double
    let swapTotalBytes: Double
    let swapFreeBytes: Double

    /// Mirrors the sweep's own thresholds so the rail turns colour when the
    /// box would start parking, not at a HUD-invented number: elevated at
    /// PSI some ≥ 5 (the sweep's hysteresis floor) or under 8G above the
    /// floor (its recovery target); critical at PSI some ≥ 10 or below the
    /// floor (when it parks).
    enum Pressure {
        case normal, elevated, critical
    }

    var availableGB: Double {
        memoryAvailableBytes / 1_073_741_824
    }

    var pressure: Pressure {
        if pressureSome >= 10 || availableGB < Double(floorGB) { return .critical }
        if pressureSome >= 5 || availableGB - Double(floorGB) < 8 { return .elevated }
        return .normal
    }

    private var usesMemoryAdmission: Bool {
        identitySlots == 0 || identities?.saved != nil
    }

    /// Modern saved identities do not form a denominator for running work.
    var shortLabel: String {
        let available = String(format: "%.0fG", availableGB)
        let activity = usesMemoryAdmission || hotCeiling <= 0
            ? "\(running) running" : "\(running) hot of \(hotCeiling)"
        return "\(activity) · \(parked) parked · \(available) free / \(floorGB)G floor"
    }

    var helpLabel: String {
        let load = String(format: "%.1f", load1)
        let psi = String(format: "%.1f/%.1f", pressureSome, pressureFull)
        var capacity = [String]()
        if usesMemoryAdmission {
            if let saved = identities?.saved { capacity.append("\(saved) saved workspaces") }
            if let leases = identities?.runtimeLeases { capacity.append("\(leases) workspaces with ports") }
            if let used = identities?.portsUsed, let total = identities?.portCapacity, total > 0 {
                capacity.append("\(used) of \(total) ports allocated")
            }
            capacity.append("admission by RAM")
        } else {
            capacity.append("\(claimed) of \(identitySlots) identities claimed")
            if hotCeiling > 0 { capacity.append("ceiling \(hotCeiling) hot (RAM-derived)") }
        }
        return capacity.joined(separator: " · ")
            + " · \(cpus) vCPU · load \(load) · memory PSI some/full \(psi)"
    }
}

/// One devbox slot. Slot 0 is the shared stack; 1..N are claimed per worktree.
///
/// Everything comes from `devbox hub --json` over ssh in one round-trip:
/// `containers`/`repos` from its embedded status doc, `memoryBytes`/
/// `cpuPercent`/`stats` from its docker-stats pass, joined by
/// `composeProject` (the label devbox stamps on every stack).
struct DevboxSlot: Identifiable, Codable {
    let n: Int
    let slug: String
    let composeProject: String
    let containerPrefix: String
    let running: Bool
    let containers: Int
    let containersTotal: Int
    let lastUsed: Int
    /// Someone ran `acquire` (slot 0 is always claimed).
    let claimed: Bool
    let entrypointPort: Int
    let repos: [DevboxRepo]

    var memoryBytes: Double?
    var cpuPercent: Double?
    /// Per-container rows for the drill-down; nil until the hub merge.
    var stats: [DevboxContainerStat]?

    var id: String {
        composeProject
    }

    var isShared: Bool {
        n == 0
    }

    var memoryLabel: String {
        guard let memoryBytes, memoryBytes > 0 else { return "—" }
        let gb = memoryBytes / 1_073_741_824
        return gb >= 10 ? String(format: "%.0fG", gb) : String(format: "%.1fG", gb)
    }

    var cpuLabel: String {
        guard let cpuPercent else { return "—" }
        return "\(Int(cpuPercent.rounded()))%"
    }

    /// Repos with anything uncommitted or unpushed — what you actually want to
    /// see at a glance when several slots exist.
    var dirtyRepos: [DevboxRepo] {
        repos.filter { !$0.isClean }
    }
}

struct DevboxProject: Identifiable, Codable {
    /// Internal tenant key ("booking-be").
    let name: String
    /// GitHub owner/repo of the primary checkout, e.g. Booking/BookingBack.
    let repoOwner: String
    let repoName: String
    /// What to print. Derived from the repo name, overridable per tenant —
    /// sample-stack's primary repo is "sample-compose", which nobody calls
    /// the project.
    let displayName: String
    var slots: [DevboxSlot]
    var id: String {
        name
    }

    /// Owner/repo for the tooltip, so the label stays short but the exact
    /// repo is one hover away.
    var repoSlug: String {
        repoOwner.isEmpty ? repoName : "\(repoOwner)/\(repoName)"
    }

    var runningSlots: [DevboxSlot] {
        slots.filter(\.running)
    }

    /// Slots worth a card: the shared stack, anything claimed, anything
    /// running. Three tenants × three slots is nine cards, most of them idle
    /// and unclaimed — enough to push the interesting ones off screen.
    var visibleSlots: [DevboxSlot] {
        slots.filter { $0.claimed || $0.running }
    }

    var freeSlotCount: Int {
        slots.count - visibleSlots.count
    }
}
