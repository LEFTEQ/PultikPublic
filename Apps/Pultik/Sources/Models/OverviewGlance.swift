import Foundation

// MARK: - Overview glances (spec 2026-09-23)
//
// What the module strip's signals, Home's tiles and the module pages show,
// derived once from state `StatusStore` already publishes (the left column
// these began in retired with WP8). Pure values, Foundation-only, so the
// focused contract harness can test them without the app. Views format;
// they never derive.

/// The CI section's headline: fleet occupancy from the lanes, red and
/// running from GitHub — the same totals `CIFooterSummary` showed.
struct CIGlance {
    /// Jobs on our lanes plus the ones the collector saw elsewhere.
    let running: Int
    let queued: Int
    let lanesDown: Int
    let failedRuns: Int
    let runningRuns: Int
    /// Every repo answered with an error — the counts above mean nothing.
    let githubUnreachable: Bool

    init(board: CILaneBoard, repos: [RepoStatus]) {
        running = board.running + board.elsewhere.count
        queued = board.lanes.reduce(0) { $0 + $1.queued } + board.elsewhereQueued
        lanesDown = board.lanes.filter { !$0.up }.count
        failedRuns = repos.reduce(0) { $0 + $1.runs.filter(\.failed).count + $1.deploys.filter(\.failed).count }
        runningRuns = repos.reduce(0) { $0 + $1.runs.filter(\.isRunning).count + $1.deploys.filter(\.isRunning).count }
        githubUnreachable = !repos.isEmpty && repos.allSatisfy { $0.error != nil }
    }

    /// The one "running" every CI surface shows. A running workflow run is
    /// also a running job, on our lanes or elsewhere, so the two never add:
    /// lane jobs while the fleet reports, GitHub's running runs otherwise.
    func runningCount(lanesReport: Bool) -> Int {
        lanesReport ? running : runningRuns
    }
}

/// The CI section's pool line (2026-09-26): every Docker lane draws on one
/// pool, so capacity is its slots and reservation budget, not a per-lane
/// `n/max`. The head is the queue's best-ranked waiter — what places next.
struct CIPoolGlance {
    let slots: String // "18/32 slots"
    let memory: String // "62/94 GiB"
    /// "exampleapp-web · tier 0 · e2e"; nil while nobody waits.
    let head: String?
    /// No slot or no reserved memory left for another job.
    let full: Bool
    /// The newest controller render is older than `staleAfter`: the numbers
    /// describe a pool that may have moved on.
    let stale: Bool

    static let staleAfter: TimeInterval = 180

    init(pool: CIPool, now: Date = Date()) {
        slots = "\(pool.slotsUsed)/\(pool.slotsMax) slots"
        memory = "\(Self.gib(pool.reservedMiB))/\(Self.gib(pool.budgetMiB)) GiB"
        head = pool.head.map { head in
            ([head.lane] + [head.tier.map { "tier \($0)" }, head.kind].compactMap { $0 })
                .joined(separator: " · ")
        }
        full = pool.slotsUsed >= pool.slotsMax || pool.reservedMiB >= pool.budgetMiB
        stale = pool.observedAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true
    }

    private static func gib(_ mib: Int) -> Int {
        Int((Double(mib) / 1024).rounded())
    }
}

/// The CI widget's day lines (2026-09-27), from Semafor's `/overview`:
/// queue wait, throughput against yesterday at the same time, and the hours
/// so far as a sparkline.
struct CIThroughputGlance {
    /// Semafor alerts when a lane's p90 wait stays over two minutes
    /// (build-server-infra `alerts/semafor.yml`); the day's p95 past the same
    /// line turns the wait orange.
    static let slowWaitSeconds: Double = 120

    /// "wait p50 3s · p95 1m22s · 0.3% > 5m"; nil before a job completed today.
    let wait: String?
    let waitSlow: Bool
    /// "640 jobs today"
    let jobs: String
    /// "+5%" / "−12%" against yesterday up to the same time; nil when
    /// yesterday had none to compare with.
    let delta: String?
    /// Jobs per local hour from midnight through the current hour — the
    /// hours still ahead are not zeros, they have not happened.
    let hours: [Int]

    init(_ throughput: CIThroughput) {
        if let queue = throughput.queue {
            var parts = ["wait p50 \(Self.duration(queue.p50))", "p95 \(Self.duration(queue.p95))"]
            if let share = throughput.over300sShare {
                parts.append("\(Self.percent(share)) > 5m")
            }
            wait = parts.joined(separator: " · ")
            waitSlow = queue.p95 > Self.slowWaitSeconds
        } else {
            wait = nil
            waitSlow = false
        }
        jobs = "\(throughput.jobs.formatted()) jobs today"
        if throughput.yesterdaySameTime > 0 {
            let change = (Double(throughput.jobs) / Double(throughput.yesterdaySameTime) - 1) * 100
            let rounded = Int(change.rounded())
            delta = rounded < 0 ? "\u{2212}\(-rounded)%" : "+\(rounded)%"
        } else {
            delta = nil
        }
        let byHour = throughput.hours.sorted { $0.hour < $1.hour }
        let now = throughput.currentHour ?? 23
        hours = byHour.filter { $0.hour <= now }.map(\.jobs)
    }

    /// "3s", "1m22s", "1h4m" — whole seconds, never a fraction.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m\(total % 60)s" }
        return "\(total / 3600)h\((total % 3600) / 60)m"
    }

    /// "0.3%" under ten percent, "12%" from there.
    static func percent(_ share: Double) -> String {
        let value = share * 100
        return value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }
}

/// The right rail's alert rows (2026-09-27): firing rules at critical or
/// warning, one row per alert name — the same rule across hosts is one
/// problem, led by its critical instance if any. Critical rows first, then
/// the most recently started, so a new fire is on top. `Watchdog` fires by
/// design and is never shown.
struct AlertGlance {
    struct Row: Identifiable, Equatable {
        let name: String
        let critical: Bool
        /// The first instance's summary, else the rule name.
        let title: String
        /// Other instances folded into this row.
        let more: Int
        /// `app · environment` of the first instance, when labelled.
        let context: String?
        /// When the newest instance started firing.
        let since: Date?
        let alerts: [FiringAlert]

        var id: String { name }
    }

    static let shownSeverities: Set<String> = ["critical", "warning"]

    let rows: [Row]
    var critical: Int { rows.filter(\.critical).count }

    init(_ alerts: [FiringAlert]) {
        let shown = alerts.filter {
            $0.state == "firing" && !$0.isHeartbeat && Self.shownSeverities.contains($0.severity ?? "")
        }
        let groups = Dictionary(grouping: shown, by: \.name)
        rows = groups.map { name, group in
            // Critical instances lead, so a red row always reads a critical
            // alert's words; newest first within each severity.
            let ordered = group.sorted { a, b in
                let (aCritical, bCritical) = (a.severity == "critical", b.severity == "critical")
                if aCritical != bCritical { return aCritical }
                return (a.activeAt ?? .distantPast) > (b.activeAt ?? .distantPast)
            }
            let first = ordered[0]
            return Row(name: name, critical: group.contains { $0.severity == "critical" },
                       title: first.summary ?? name, more: group.count - 1,
                       context: first.context,
                       since: first.activeAt, alerts: ordered)
        }
        .sorted { a, b in
            if a.critical != b.critical { return a.critical }
            return (a.since ?? .distantPast, b.name) > (b.since ?? .distantPast, a.name)
        }
    }
}

/// Semafor's refusal reasons in the words its own admission page uses
/// (semafor `web/src/routes/admission.tsx` `REASON_LABEL`), so the widget
/// and the page it links to say the same thing.
enum CIRefusalReason {
    static func label(_ reason: String) -> String {
        switch reason {
        case "fifo": "FIFO"
        case "mem_budget": "mem budget"
        case "io_psi": "IO PSI"
        case "mem_psi": "mem PSI"
        case "mem_available": "MemAvailable"
        default: reason // partition, containers — already words
        }
    }
}

/// The Estate widget's services line. A probe without an answer is unknown,
/// never down: the laptop off the mesh must not paint the estate red.
struct EstateGlance {
    let total: Int
    let up: Int
    let unknown: Int
    /// Named, never folded into a count.
    let down: [ServiceStatus]
    /// Median over services that are up and reported a latency.
    let medianLatencySeconds: Double?

    init(services: [ServiceStatus]) {
        total = services.count
        up = services.filter { $0.up == true }.count
        unknown = services.filter { $0.up == nil }.count
        down = services.filter { $0.up == false }
        let latencies = services.filter { $0.up == true }.compactMap(\.latencySeconds).sorted()
        if latencies.isEmpty {
            medianLatencySeconds = nil
        } else if latencies.count.isMultiple(of: 2) {
            let upper = latencies.count / 2
            medianLatencySeconds = (latencies[upper - 1] + latencies[upper]) / 2
        } else {
            medianLatencySeconds = latencies[latencies.count / 2]
        }
    }
}

