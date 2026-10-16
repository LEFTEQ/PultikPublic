import Foundation

// Semafor's history reads (vt-7781 WP4): the CI and Estate timelines with
// their server bins, the replay instants (`/ci/at`, `/estate/map?at=`,
// `/estate/backups?at=`) and the estate topology. Contracts:
// infra/semafor/docs/contracts/api-v1.md ("CI timeline routes") and
// estate-api.md. Decoded with `SemaforTime.decoder()`: snake_case keys reach
// these camelCase properties, and every time is a `Date` — an instant in
// UTC; the Rust timeline reads `timeIntervalSince1970` (seconds). Durations
// and periods are whole or fractional seconds (`…S`), sizes bytes, memory
// MiB. The snapshot coder's default strategies round-trip them exactly (a
// `Date` travels as a number). Foundation-only: `tools/test-foundation.sh`
// builds it.

// MARK: - CI timeline

/// One job on `/api/v1/ci/timeline`: a finished record, a GitHub-hosted
/// job, or an open workflow job (`running` / `waiting`) with no record yet.
struct CITimelineJob: Codable, Sendable, Equatable, Identifiable {
    /// The runner (`ci-jit-<lane>-<8 hex>`) for a finished fleet job;
    /// `gh-<ghJobId>` for a GitHub-hosted job and for every open one. A
    /// fleet job therefore changes id when it finishes: `ghJobId` joins
    /// the two copies (`TimelinePages` drops the open one).
    var id: String
    /// `gh:<owner>/<repo>` for a hosted job.
    var lane: String
    /// `docker` · `kvm` · `hosted` · `""` (not yet known).
    var backend: String
    /// `""` (the shared pool) · `kvm` · `hosted`.
    var partition: String
    /// The controller's job record id; `""` for an open job.
    var jobId: String
    var runId: Int64
    var queuedAt: Date
    /// The effective start; nil while waiting.
    var startedAt: Date?
    /// Nil while open.
    var completedAt: Date?
    /// `succeeded` · `failed` · `cancelled` · `unknown` · `running` · `waiting`.
    var result: String
    /// MiB; nil for a hosted or open job.
    var reservedMib: Int?
    var hardCapMib: Int?
    var peakMib: Int?
    /// Times admission refused it.
    var refusals: Int
    var repo: String
    /// `repo` came from the job's own webhook, not its lane's majority.
    var repoOwn: Bool
    var name: String?
    var ghJobId: Int64?
    var runAttempt: Int?
    var workflow: String?
    var branch: String?
    var sha: String?
    var pr: Int?
    var actor: String?
    var hosted: Bool

    /// The timeline's start (Semafor's `jobStart`): when it was queued.
    var start: Date { queuedAt }
    var isOpen: Bool { result == "running" || result == "waiting" }
}

/// One lane's jobs completed in `[from, from + bucket)`, the bucket epoch
/// aligned. Records only: GitHub-hosted jobs are never binned (on
/// build-server's busiest day 2,718 of 2,876 jobs), so hosted lanes have none.
struct CITimelineBin: Codable, Sendable, Equatable {
    var lane: String
    var from: Date
    var count: Int
    var failures: Int
    var cancelled: Int
}

/// A `/api/v1/ci/timeline` page: raw jobs (no `bucket`) completed in
/// `[from, to)`, oldest queued first, at most 4,000 — past that `from` and
/// `older` move to the oldest kept completion — or per-lane bins. A page
/// reaching now also carries the open jobs.
struct CITimelinePage: Codable, Sendable, Equatable {
    var from: Date
    var to: Date
    /// The server's clock when it answered.
    var now: Date
    /// The next older page's `before`; nil once `recordedSince` is reached.
    var older: Date?
    var recordedSince: Date?
    var jobs: [CITimelineJob]
    var bins: [CITimelineBin]
}

/// `/api/v1/ci/at?t=`: every lane with a job record spanning `at`.
/// Records only, no pool budget (never stored).
struct SemaforCIAt: Codable, Sendable, Equatable {
    var at: Date
    var lanes: [Lane]

    struct Lane: Codable, Sendable, Equatable {
        var lane: String
        /// Effective start ≤ at < completion.
        var running: Int
        /// Queued ≤ at < effective start.
        var waiting: Int
        /// The running jobs' reservations, MiB.
        var reservedMib: Int
    }
}

/// The playhead's state at one instant (vt-7781), each host's answer by its
/// ref: CI's pool cards (`/ci/at`, the chip's host), the estate's box cards
/// (`/estate/map?at=`) or the backups (`/estate/backups?at=`, every host).
struct TimelineReplay: Sendable, Equatable {
    var lens: TimelineLens
    var at: Date
    var ci: [String: SemaforCIAt] = [:]
    var maps: [String: SemaforEstateMap] = [:]
    var backups: [String: SemaforBackups] = [:]
}

// MARK: - Estate timeline

/// Which estate timeline a page is: the default (rollouts, backups and
/// cleanups per box) or `view=backups` (one row per backup surface).
enum EstateTimelineView: String, Codable, Sendable {
    case estate, backups
}

/// One event of `/api/v1/estate/timeline`. `id` is stable across pages and
/// polls. A rollout is one event at its start; a scheduled one (a timer's
/// next run, right of now) has id `next-<box>-<unit>-<unix s>`.
struct EstateTimelineEvent: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var at: Date
    var box: String
    /// `reconcile` · `gateway` · `eve` (rollouts) · `backup` · `restore`
    /// (backups) · `cleanup` · `cert` (cleanups).
    var kind: String
    /// `ok` · `fail` · `rollback` · `live` · `missed` · `scheduled`.
    var result: String
    var title: String
    var subtitle: String?
    var app: String?
    var sha: String?
    var shaFull: String?
    var repo: String?
    var durationS: Double?
    var sizeBytes: Int64?
    /// Semafor's `where`.
    var location: String?
    var note: String?
    var command: String?
    var stage: String?
    /// A backup or restore run's backup (its matrix row) and pipeline.
    var surface: String?
    var pipeline: String?

    enum CodingKeys: String, CodingKey {
        case id, at, box, kind, result, title, subtitle, app, sha, shaFull, repo, durationS, sizeBytes
        case location = "where"
        case note, command, stage, surface, pipeline
    }

    var start: Date { at }
    var isScheduled: Bool { result == "scheduled" }
    var isLive: Bool { result == "live" }
    /// The lane row, derived from `kind` (never sent).
    var row: String { Self.row(kind) }

    static func row(_ kind: String) -> String {
        switch kind {
        case "backup", "restore": "backups"
        case "cleanup", "cert": "cleanups"
        default: "rollouts"
        }
    }
}

/// Per box, per row counts in `[from, from + bucket)`, epoch aligned; a
/// bin of future timer runs is `scheduled`. `failures` counts `fail`.
struct EstateTimelineBin: Codable, Sendable, Equatable {
    var box: String
    /// `rollouts` · `backups` · `cleanups`.
    var row: String
    var from: Date
    var count: Int
    var failures: Int
    var scheduled: Bool
    /// `view=backups`: the backup this bin counts (its row).
    var surface: String?
}

/// A rollback pin over a time range; `to` nil = still pinned.
struct EstateTimelinePin: Codable, Sendable, Equatable {
    var box: String
    var from: Date
    var to: Date?
    var sha: String
    var label: String
}

/// A periodic timer whose repeats the client draws: at
/// `nextAt + k × periodS` while before the page's `to`, ids
/// `next-<box>-<unit>-<unix s>`.
struct EstateTimelineSchedule: Codable, Sendable, Equatable {
    var box: String
    var unit: String
    /// The event kind its marks draw as.
    var kind: String
    /// The one `scheduled` event the page carries for it.
    var nextAt: Date
    /// Seconds, > 0 (observed: next − last trigger, jitter included).
    var periodS: Int64
    /// `view=backups`: the backup the timer runs.
    var surface: String?

    /// The id prefix of its scheduled marks.
    var repeatPrefix: String { "next-\(box)-\(unit)-" }
    /// The id of its next run's mark.
    var nextID: String { repeatPrefix + String(Int64(nextAt.timeIntervalSince1970.rounded(.down))) }
}

/// A `/api/v1/estate/timeline` page: events at `[from, to)` (a raw page
/// stops at 5,000 stored events, then `from` and `older` move to where it
/// stopped), or (`bucket`) density bins; pins overlapping the window, and
/// on a raw page the schedules whose repeats the client draws.
struct EstateTimelinePage: Codable, Sendable, Equatable {
    var from: Date
    var to: Date
    var now: Date
    var older: Date?
    var recordedSince: Date?
    var events: [EstateTimelineEvent]
    var buckets: [EstateTimelineBin]
    var pins: [EstateTimelinePin]
    var schedules: [EstateTimelineSchedule]
}

// MARK: - Topology

/// `/api/v1/estate/topology`: how the boxes, the key box, GitHub and the
/// backup storage connect — configured intent, never observed traffic.
/// `app:<box>/<app>` endpoints are not nodes: they resolve against `/map`.
struct SemaforEstateTopology: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var note: String?
    var nodes: [Node]
    var edges: [Edge]

    struct Node: Codable, Sendable, Equatable, Identifiable {
        /// `box:<name>` · `ext:<name>` · `store:<name>`.
        var id: String
        /// `box` · `external-box` · `external` · `storage`.
        var kind: String
        var label: String
        var detail: String?
        /// `public` · `admin` · `p2p`; absent when none.
        var addresses: [String: String]?
        /// A storage node's backup column: `storage_box` · `s3` · `vault`.
        var place: String?
        var sources: [Source]?
    }

    struct Edge: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var from: String
        var to: String
        /// `wireguard` · `telemetry` · `observe` · `ci` · `deploy` · `backup`
        /// · `data` · `keystore` · `restore` · `errors`.
        var kind: String
        /// `one-way` · `both`.
        var direction: String
        var label: String?
        var detail: String?
        /// Gateway → app `deploy` edges: the deploy-gateway targets on it.
        var targets: [String]?
        var sources: [Source]?
    }

    struct Source: Codable, Sendable, Equatable {
        var repo: String
        var path: String
    }
}
