import Foundation

// Semafor's v1 read API as Pultík reads it (vt-7727 D2: a native client on
// the JSON as it is; contracts in infra/semafor/docs/contracts/). Live
// answers decode with `convertFromSnakeCase`, so properties are camelCase
// and a key with a digit names its mangled form in `CodingKeys`
// (`jobs_30d` reaches the container as `jobs30D`); the snapshot coder's
// default strategies then round-trip the same keys. Times stay RFC 3339
// strings, read through `SemaforTime`. Arrays a Go nil slice may send as
// null are optional; the `…List` accessors read them as empty.
// Foundation-only: `tools/test-foundation.sh` builds it.

enum SemaforTime {
    /// RFC 3339 with or without fractional seconds — Semafor sends up to
    /// nanoseconds (`17:52:03.402934261Z`), more than the formatter reads:
    /// the whole seconds parse, the fraction is added (to the microsecond),
    /// so a job's outcome is never read as the moment before it.
    static func date(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if let parsed = text.utf8.withContiguousStorageIfAvailable(rfc3339), let parsed { return parsed }
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        {
            let digits = text[text.index(after: dot)..<end]
            guard digits.allSatisfy(\.isASCII), let fraction = Double("0." + digits.prefix(6)) else { return nil }
            text.removeSubrange(dot..<end)
            return plain.date(from: text)?.addingTimeInterval(fraction)
        }
        return plain.date(from: text)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` read by hand: the
    /// formatter costs ~26 µs a parse, which made a busiest-day CI page
    /// (8,600 times) take 320 ms to decode. Nil hands anything else to it.
    private static func rfc3339(_ s: UnsafeBufferPointer<UInt8>) -> Date? {
        func number(_ at: Int, _ count: Int) -> Int? {
            var value = 0
            for i in at..<at + count {
                let digit = Int(s[i]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard s.count >= 20, s[4] == 45, s[7] == 45, s[10] == 84 || s[10] == 116, s[13] == 58, s[16] == 58,
              let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
              let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var i = 19
        var fraction = 0.0
        if s[i] == 46 { // .
            var digits = 0
            var scale = 1
            i += 1
            while i < s.count, (48...57).contains(s[i]) {
                if scale < 1_000_000_000 {
                    digits = digits * 10 + Int(s[i]) - 48
                    scale *= 10
                }
                i += 1
            }
            guard scale > 1 else { return nil }
            fraction = Double(digits) / Double(scale)
        }
        guard i < s.count else { return nil }
        var offset = 0
        switch s[i] {
        case 90, 122: // Z z
            i += 1
        case 43, 45: // + -
            guard s.count - i == 6, s[i + 3] == 58, let h = number(i + 1, 2), let m = number(i + 4, 2) else { return nil }
            offset = (h * 3600 + m * 60) * (s[i] == 43 ? 1 : -1)
            i += 6
        default:
            return nil
        }
        guard i == s.count else { return nil }
        // Days since 1970-01-01 (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction)
    }

    /// RFC 3339 for a query (`at=`, `t=`, `before=`).
    static func string(_ date: Date) -> String { plain.string(from: date) }

    /// A replay instant (`/ci/at?t=`, `?at=`) to the millisecond, rounded
    /// up: a playhead settled on a mark's outcome asks for the state after
    /// it, never the moment before (Semafor's `replay.ts`).
    static func replayString(_ date: Date) -> String {
        // A thousandth of a millisecond under: floating-point noise on a
        // whole millisecond never rounds it up a whole one.
        let ms = Int64((date.timeIntervalSince1970 * 1000 - 0.001).rounded(.up))
        let seconds = ms.quotientAndRemainder(dividingBy: 1000)
        let whole = seconds.remainder < 0 ? seconds.quotient - 1 : seconds.quotient
        let fraction = seconds.remainder < 0 ? seconds.remainder + 1000 : seconds.remainder
        let text = plain.string(from: Date(timeIntervalSince1970: TimeInterval(whole)))
        return String(text.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The API decoder: snake_case keys, and a `Date` property reads an
    /// RFC 3339 string (the history models, `SemaforHistory.swift`; the
    /// phase-1 views keep their times as strings).
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = SemaforTime.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an RFC 3339 time: \(text)")
            }
            return date
        }
        return decoder
    }
}

// MARK: - Estate

/// `/api/v1/estate/map`: every box the Semafor reconciles, its apps and
/// vitals; with `?at=` the replay at that moment (`live` false, vitals nil,
/// `liveRollouts` what was running then).
struct SemaforEstateMap: Codable, Sendable, Equatable {
    var at: String?
    var live: Bool?
    var observedAt: String?
    var boxes: [Box]?

    var boxList: [Box] { boxes ?? [] }

    struct Box: Codable, Sendable, Equatable {
        var name: String
        /// Its admin address, beside its name on the map.
        var addr: String?
        /// `synced` · `seeded` · `rolling` · `pending` · `held` · `errors` ·
        /// `pinned` · `unreachable` — the box as a whole, never a backup verdict.
        var sync: String?
        /// Commits of `origin/main` not yet applied.
        var ahead: Int?
        var tickAt: String?
        var toolkitVersion: String?
        var applied: Commit?
        var originMain: Commit?
        var apps: [App]?
        var vitals: Vitals?
        /// A rollback pin in force; nil while unpinned.
        var pin: Pin?
        /// What is rolling out (in a replay: what was, at `at`).
        var liveRollouts: [LiveRollout]?

        var appList: [App] { apps ?? [] }
        /// Apps not where `origin/main` wants them: `roll` is pending; `elsewhere` is owned elsewhere.
        var pendingApps: [App] { appList.filter { $0.sync == "roll" } }
        var syncedCount: Int { appList.filter { $0.sync != "roll" }.count }
    }

    struct Commit: Codable, Sendable, Equatable {
        var sha: String?
        var subject: String?
    }

    struct Pin: Codable, Sendable, Equatable {
        var sha: String?
        var full: String?
        var since: String?
        var reason: String?
    }

    struct LiveRollout: Codable, Sendable, Equatable {
        var id: String
        var kind: String?
        var title: String?
        var stage: String?
        var app: String?
        /// The deploy-gateway target (a topology deploy edge's `targets`).
        var target: String?
        var startedAt: String?
    }

    struct App: Codable, Sendable, Equatable {
        var name: String
        /// `synced` · `roll` (pending) · `elsewhere`.
        var sync: String?
        /// `healthy` · `degraded` · `down` · `unknown`.
        var health: String?
        var note: String?
    }

    struct Vitals: Codable, Sendable, Equatable {
        var host: Machine?
        var guests: [Machine]?
        var ci: CI?
        var zfsPools: [Pool]?
    }

    struct Machine: Codable, Sendable, Equatable {
        var name: String
        var cores: Int?
        /// 0…1 of all cores.
        var cpuBusy: Double?
        var load1: Double?
        var memTotalBytes: Double?
        var memAvailableBytes: Double?
        var rootSizeBytes: Double?
        var rootAvailBytes: Double?
        var bootedAt: String?
    }

    struct CI: Codable, Sendable, Equatable {
        var controllers: Int?
        var controllersUp: Int?
        var fireflyRunning: Bool?
        var lanes: Int?
    }

    struct Pool: Codable, Sendable, Equatable {
        var name: String
        var state: String?
        var sizeBytes: Double?
        var allocatedBytes: Double?
        var dataErrors: Int?
    }
}

/// `/api/v1/estate/findings`: what Semafor says needs a look, per box.
struct SemaforFinding: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var box: String
    var app: String?
    /// `stop` or `wait`.
    var severity: String
    var title: String
    var why: String?
    var since: String?
    var command: String?

    static func decode(_ data: Data) throws -> [SemaforFinding] {
        struct Answer: Decodable { let findings: [SemaforFinding]? }
        return try SemaforTime.decoder().decode(Answer.self, from: data).findings ?? []
    }
}

/// `/api/v1/estate/backups`: one pipeline per (box, surface) with each
/// place's freshness. Semafor sends no verdict; `BackupVerdict` computes it.
struct SemaforBackups: Codable, Sendable, Equatable {
    var at: String?
    var pipelines: [Pipeline]?

    var pipelineList: [Pipeline] { pipelines ?? [] }

    struct Pipeline: Codable, Sendable, Equatable {
        var box: String
        var name: String
        var cadence: String?
        var lastOkAt: String?
        /// The largest of its places' budgets; 0 or nil = unknown.
        var maxAgeS: Double?
        var sizeBytes: Double?
        var places: [String: Place]?
        var schedule: Schedule?

        var id: String { "\(box)/\(name)" }
        func place(_ kind: BackupPlace) -> Place? { places?[kind.rawValue] }
    }

    struct Place: Codable, Sendable, Equatable {
        /// `none` · `fresh` · `near` · `stale`.
        var state: String
        var ageS: Double?
        var location: String?
        var unit: String?
        var detail: String?
        var encrypted: Bool?
    }

    struct Schedule: Codable, Sendable, Equatable {
        var unit: String?
        var periodS: Double?
        var nextAt: String?
        var lastTriggerAt: String?
    }
}

/// A backup's places in the Pipelines table's column order; `restore` is
/// the proof, not a copy of the data.
enum BackupPlace: String, CaseIterable, Sendable {
    case local
    case storageBox = "storage_box"
    case s3, vault, restore

    var title: String {
        switch self {
        case .local: "Local"
        case .storageBox: "Storage Box"
        case .s3: "S3"
        case .vault: "Vault"
        case .restore: "Restore"
        }
    }

    static let data: [BackupPlace] = [.local, .storageBox, .s3, .vault]
}

/// Semafor's backup verdict as its own UI computes it
/// (`web/src/components/estate/backup-vocab.ts`, `backups-timeline.tsx`):
/// a pipeline stops when no good write is fresh, a data copy is stale or
/// the restore proof is stale; waits when any place is near its budget;
/// goes otherwise. A box takes its worst pipeline; no pipeline goes.
enum BackupVerdict: Int, Comparable, Sendable {
    case go, wait, stop

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func of(_ pipeline: SemaforBackups.Pipeline, now: Date) -> BackupVerdict {
        let lastOk = SemaforTime.date(pipeline.lastOkAt)
        let budget = pipeline.maxAgeS ?? 0
        let overdue = lastOk.map { budget > 0 && max(0, now.timeIntervalSince($0)) > budget } ?? false
        let dataStale = BackupPlace.data.contains { pipeline.place($0)?.state == "stale" }
        let fresh = lastOk != nil && !overdue && !dataStale
        if !fresh || pipeline.place(.restore)?.state == "stale" { return .stop }
        if BackupPlace.allCases.contains(where: { pipeline.place($0)?.state == "near" }) { return .wait }
        return .go
    }

    static func box(_ pipelines: [SemaforBackups.Pipeline], now: Date) -> BackupVerdict {
        pipelines.map { of($0, now: now) }.max() ?? .go
    }
}

// MARK: - CI

/// `/api/v1/ci/lanes`: every lane the Semafor attributed in 30 days,
/// GitHub-hosted ones (`gh:<owner>/<repo>`, partition `hosted`) included.
struct SemaforCILane: Codable, Sendable, Equatable {
    var lane: String
    var repo: String?
    var backend: String?
    var partition: String?
    var reservedMib: Int?
    var hardCapMib: Int?
    var jobs30d: Int?

    var isHosted: Bool { partition == "hosted" || lane.hasPrefix("gh:") }

    enum CodingKeys: String, CodingKey {
        case lane, repo, backend, partition, reservedMib, hardCapMib
        case jobs30d = "jobs30D"
    }

    static func decode(_ data: Data) throws -> [SemaforCILane] {
        struct Answer: Decodable { let lanes: [SemaforCILane]? }
        return try SemaforTime.decoder().decode(Answer.self, from: data).lanes ?? []
    }
}

/// One job of `/api/v1/ci/timeline`'s page.
struct SemaforJob: Codable, Sendable, Equatable, Identifiable {
    /// `gh-<gh_job_id>` for a hosted job; the record id otherwise.
    var id: String
    var ghJobId: Int64?
    var runId: Int64?
    var repo: String
    var workflow: String?
    var name: String
    var lane: String
    var backend: String?
    var partition: String?
    var hosted: Bool?
    /// `running` · `waiting` · `succeeded` · `failed` · `cancelled`.
    var result: String
    var queuedAt: String?
    var startedAt: String?
    var completedAt: String?
    var branch: String?
    var pr: Int?

    var isHosted: Bool { hosted == true || partition == "hosted" }
    var isLive: Bool { result == "running" || result == "waiting" }
}

/// A `/api/v1/ci/timeline` page: one window of jobs and the cursor to the
/// window before it.
struct SemaforTimelinePage: Codable, Sendable, Equatable {
    var from: String?
    var to: String?
    var now: String?
    var older: String?
    var jobs: [SemaforJob]?

    var jobList: [SemaforJob] { jobs ?? [] }
}

/// One workflow run (`/api/v1/ci/runs`, and `run` of a run's detail).
struct SemaforRun: Codable, Sendable, Equatable, Identifiable {
    var runId: Int64
    var runNumber: Int?
    var repo: String
    var workflow: String
    var title: String?
    var branch: String?
    var event: String?
    /// `running` · `waiting` · `succeeded` · `failed` · `cancelled` · `skipped`.
    var result: String
    var createdAt: String?
    var startedAt: String?
    var completedAt: String?
    var durationS: Double?
    var waitS: Double?
    var htmlUrl: String?
    var attempt: Int?
    var jobs: JobCounts?
    var actor: Actor?
    var prs: [PR]?

    var id: Int64 { runId }

    struct JobCounts: Codable, Sendable, Equatable {
        var total: Int?
        var failed: Int?
        var running: Int?
        var waiting: Int?
    }

    struct Actor: Codable, Sendable, Equatable {
        var login: String
    }

    struct PR: Codable, Sendable, Equatable {
        var number: Int
        var title: String?
    }

    static func decode(_ data: Data) throws -> [SemaforRun] {
        struct Answer: Decodable { let runs: [SemaforRun]? }
        return try SemaforTime.decoder().decode(Answer.self, from: data).runs ?? []
    }
}

/// `/api/v1/ci/workflows?window=7d`: each workflow's runs, rates and
/// percentiles, plus the flaky and slowest jobs.
struct SemaforWorkflows: Codable, Sendable, Equatable {
    var window: String?
    var workflows: [Workflow]?
    var flaky: [Flaky]?

    var workflowList: [Workflow] { workflows ?? [] }

    struct Workflow: Codable, Sendable, Equatable {
        var repo: String
        var workflow: String
        var path: String?
        var runs: Int
        var succeeded: Int?
        var failed: Int?
        var cancelled: Int?
        var successRate: Double?
        var p50S: Double?
        var p95S: Double?
        var waitP95S: Double?
        var trend: [Day]?

        var id: String { "\(repo)/\(path ?? workflow)" }
    }

    struct Day: Codable, Sendable, Equatable {
        var day: String
        var runs: Int
        var failures: Int?
    }

    struct Flaky: Codable, Sendable, Equatable {
        var repo: String
        var workflow: String
        var name: String
        var flaky: Int
        var runs: Int?
    }
}

/// `/api/v1/ci/failures?window=7d`: failed jobs clustered by first error.
struct SemaforFailures: Codable, Sendable, Equatable {
    var clusters: [Cluster]?
    var pending: Int?
    var unreadable: Int?

    var clusterList: [Cluster] { clusters ?? [] }

    struct Cluster: Codable, Sendable, Equatable {
        var key: String
        var count: Int
        var firstAt: String?
        var lastAt: String?
        var firstError: String?
        var jobs: [String]?
        var repos: [String]?
        var workflows: [String]?
        var latest: Latest?
    }

    struct Latest: Codable, Sendable, Equatable {
        var repo: String?
        var job: String?
        var runId: Int64?
        var stepName: String?
        var htmlUrl: String?
    }
}

/// `/api/v1/ci/runs/{run_id}`: a run's jobs, its needs graph and critical path.
struct SemaforRunDetail: Codable, Sendable, Equatable {
    var run: SemaforRun
    var jobs: [Job]?
    var graph: Graph?
    var criticalPath: CriticalPath?

    struct Job: Codable, Sendable, Equatable {
        var ghJobId: Int64?
        var name: String
        var node: String?
        var result: String?
        var startedAt: String?
        var completedAt: String?
        var runS: Double?
        var waitS: Double?
        var lane: String?
        var htmlUrl: String?
    }

    struct Graph: Codable, Sendable, Equatable {
        /// `yaml` (the workflow's `needs:`) or `inferred` (from timings).
        var source: String?
        var nodes: [Node]?
        var error: String?
    }

    struct Node: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        /// `job` or `group` (a reusable workflow's inner jobs).
        var kind: String?
        var parent: String?
        var needs: [String]?
        var result: String?
        var startedAt: String?
        var completedAt: String?
    }

    struct CriticalPath: Codable, Sendable, Equatable {
        var nodes: [String]?
        /// From the attempt's start to the last completion, not a sum of runtimes.
        var seconds: Double?
    }

    static func decode(_ data: Data) throws -> SemaforRunDetail {
        try SemaforTime.decoder().decode(SemaforRunDetail.self, from: data)
    }
}

// MARK: - Per host

/// What one host's Semafor last answered, by resource, with when — the
/// snapshot a view paints from before its next read (D10). Each piece is
/// nil until read; an unreachable host keeps its pieces "as of" their time.
struct SemaforHostState: Codable, Sendable, Equatable {
    var map: SemaforEstateMap?
    var findings: [SemaforFinding]?
    var backups: SemaforBackups?
    var lanes: [SemaforCILane]?
    var runs: [SemaforRun]?
    var workflows: SemaforWorkflows?
    var failures: SemaforFailures?
    /// The live edge: the newest hour of `/ci/timeline`.
    var liveEdge: SemaforTimelinePage?
    /// `/estate/topology`, read on entering the Map (vt-7781).
    var topology: SemaforEstateTopology?
    /// Resource name → when it answered.
    var fetchedAt: [String: Date] = [:]
    /// Since when the host has not answered; nil while it does.
    var unreachableSince: Date?
}

/// The CI rules across two Semafors (D6, D14): fleet lanes follow the host
/// chip, keyed host + lane; GitHub-hosted jobs are the same on every
/// Semafor, so they are drawn once, from the Semafor that lists more hosted
/// lanes — never summed.
enum SemaforCI {
    /// The host whose Semafor reads the hosted lanes: most hosted lanes,
    /// the earlier host (Settings order) on a tie.
    static func hostedSource(_ hosts: [(host: String, state: SemaforHostState)]) -> String? {
        var best: (host: String, count: Int)?
        for (host, state) in hosts {
            let count = (state.lanes ?? []).filter(\.isHosted).count
            if count > (best?.count ?? -1), state.lanes != nil || state.liveEdge != nil { best = (host, count) }
        }
        return best?.host
    }

    /// The hosted jobs to draw: the hosted source's alone, by job id.
    static func hostedJobs(_ hosts: [(host: String, state: SemaforHostState)]) -> [SemaforJob] {
        guard let source = hostedSource(hosts),
              let page = hosts.first(where: { $0.host == source })?.state.liveEdge else { return [] }
        var seen = Set<String>()
        return page.jobList.filter { $0.isHosted && seen.insert($0.id).inserted }
    }

    /// A fleet row's key: the same lane name on two hosts is two rows.
    static func fleetKey(host: String, lane: String) -> String { "\(host)/\(lane)" }

    /// The default host chip: the host whose CI timeline window holds the
    /// most fleet jobs queued in its newest hour (`now`, the window's server
    /// clock), the earlier on a tie. Hosted jobs are no host's. `jobs` are
    /// sorted by start, so only the hour's tail is read.
    static func busiestHost(_ hosts: [(host: String, jobs: [CITimelineJob], now: Date?)]) -> String? {
        var best: (host: String, count: Int)?
        for (host, jobs, now) in hosts {
            let since = (now ?? jobs.last?.start ?? .distantPast).addingTimeInterval(-3600)
            let count = jobs.reversed().prefix { $0.start >= since }.count { !$0.hosted }
            if count > (best?.count ?? -1) { best = (host, count) }
        }
        return best?.host
    }

    /// The CI timeline's jobs: the chip host's fleet jobs and the hosted
    /// source's hosted jobs, each once by id — never one host's hosted jobs
    /// beside the other's. Both inputs are sorted by (start, id), and so is
    /// the answer.
    static func timelineJobs(fleet: [CITimelineJob], hosted: [CITimelineJob]) -> [CITimelineJob] {
        var seen = Set<String>()
        let jobs = fleet.filter { !$0.hosted && seen.insert($0.id).inserted }
            + hosted.filter { $0.hosted && seen.insert($0.id).inserted }
        return jobs.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
}
