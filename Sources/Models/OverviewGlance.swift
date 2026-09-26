import Foundation

// MARK: - Overview glances (spec 2026-09-23)
//
// What the left column's widgets show, derived once from state `StatusStore`
// already publishes. Pure values, Foundation-only, so the focused contract
// harness can test them without the app. Views format; they never derive.

/// The Devbox widget's numbers: capacity, the workspace pile, and the alert
/// line that appears only when something past a threshold explains a slow box.
struct DevboxGlance {
    static let gib: Double = 1_073_741_824
    /// Parked longer than this is stale — what the gc trash would clear. A
    /// heuristic from `parkedAt`; the box knows nothing about dead branches.
    static let staleAfter: TimeInterval = 7 * 86_400
    /// Memory PSI some avg10, in percent — the sweep's own hysteresis floor.
    static let pressureAlertPercent: Double = 5
    static let swapAlertBytes: Double = 0.5 * gib
    static let loadAlertPerCore: Double = 1
    static let slotsAlertFraction: Double = 0.8

    let cpuPercent: Double?
    let cores: Int
    let memoryUsedBytes: Double
    let memoryTotalBytes: Double
    /// The protected MemAvailable line — where the RAM gauge's tick sits,
    /// measured from the top: used past `memoryTotalBytes - floorBytes`
    /// means below the floor.
    let floorBytes: Double
    /// Available minus the floor; negative when the box is below it.
    let headroomBytes: Double
    let diskUsedBytes: Double?
    let diskTotalBytes: Double?
    /// Hot workspaces, heaviest first — the widget's chips.
    let running: [DevboxWorkspace]
    let parked: Int
    let stale: Int
    let held: Int
    let pressurePercent: Double
    let swapUsedBytes: Double
    let load1: Double
    /// nil without a core count — no ratio is invented.
    let loadPerCore: Double?
    /// Ports on a memory-admission box, identities on an older one; nil
    /// when the payload carries neither.
    let slotsUsed: Int?
    let slotsTotal: Int?
    let alerts: [DevboxAlert]
    /// The per-box breakdown under the combined gauges — empty with a
    /// single box, so the one-box widget is exactly what it was.
    let boxes: [DevboxBoxShare]

    /// Counts come from the workspace list, not the summary's totals, so
    /// the widget and the `.devbox` page never disagree about the pile.
    init(summary: DevboxOverviewSummary, workspaces: [DevboxWorkspace], now: Date = Date()) {
        cpuPercent = summary.cpuUsagePercent
        cores = summary.cpus
        memoryTotalBytes = summary.memoryTotalBytes
        memoryUsedBytes = max(0, summary.memoryTotalBytes - summary.memoryAvailableBytes)
        floorBytes = Double(summary.floorGB) * Self.gib
        headroomBytes = summary.memoryAvailableBytes - floorBytes
        diskUsedBytes = summary.diskUsedBytes
        diskTotalBytes = summary.diskTotalBytes
        running = workspaces.filter(\.isHot).sorted { $0.memoryBytes > $1.memoryBytes }
        let parkedSpaces = workspaces.filter(\.isParked)
        parked = parkedSpaces.count
        // Held workspaces are exempt: `gc --retire-stale` never clears them.
        stale = parkedSpaces.filter { workspace in
            guard !workspace.hold, let parkedAt = workspace.parkedAt else { return false }
            return now.timeIntervalSince(parkedAt) > Self.staleAfter
        }.count
        held = workspaces.filter(\.hold).count
        pressurePercent = summary.pressureSome
        swapUsedBytes = max(0, summary.swapTotalBytes - summary.swapFreeBytes)
        load1 = summary.load1
        loadPerCore = summary.cpus > 0 ? summary.load1 / Double(summary.cpus) : nil
        if let used = summary.identities?.portsUsed, let total = summary.identities?.portCapacity {
            slotsUsed = used
            slotsTotal = total
        } else if summary.identitySlots > 0 {
            slotsUsed = summary.claimed
            slotsTotal = summary.identitySlots
        } else {
            slotsUsed = nil
            slotsTotal = nil
        }
        boxes = summary.boxes.count > 1 ? summary.boxes : []

        var alerts: [DevboxAlert] = []
        if pressurePercent > Self.pressureAlertPercent { alerts.append(.pressure(percent: pressurePercent)) }
        if swapUsedBytes > Self.swapAlertBytes { alerts.append(.swap(bytes: swapUsedBytes)) }
        if let loadPerCore, loadPerCore > Self.loadAlertPerCore { alerts.append(.load(perCore: loadPerCore)) }
        if let slotsUsed, let slotsTotal, slotsTotal > 0,
           Double(slotsUsed) / Double(slotsTotal) > Self.slotsAlertFraction {
            alerts.append(.slots(used: slotsUsed, total: slotsTotal))
        }
        self.alerts = alerts
    }

    /// "41" / "7.5" — whole gigabytes from ten up, one decimal below.
    static func compact(_ bytes: Double) -> String {
        let gb = bytes / gib
        return gb >= 10 ? String(format: "%.0f", gb) : String(format: "%.1f", gb)
    }
}

/// One reason the Devbox is under strain, in the alert line's own words.
enum DevboxAlert: Equatable {
    case pressure(percent: Double)
    case swap(bytes: Double)
    case load(perCore: Double)
    case slots(used: Int, total: Int)

    var label: String {
        switch self {
        case let .pressure(percent): String(format: "psi %.1f%%", percent)
        case let .swap(bytes): String(format: "swap %.1f G", bytes / DevboxGlance.gib)
        case let .load(perCore): String(format: "load %.1f/core", perCore)
        case let .slots(used, total): "ports \(used)/\(total)"
        }
    }
}

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

/// The reason vocabulary `VitrinkaWorkspaceSnapshot.today` writes.
enum VitrinkaReason {
    static let needsYou = "needs you"
    static let overdue = "overdue"
    static let dueNow = "due now"
    static let inProgress = "in progress"
    /// Attention, in the order the top rows rank it.
    static let attention = [needsYou, overdue, dueNow]
}

/// The Vitrinka widget's counts line, its top rows and the picker's
/// elsewhere badge. Generic over the row so it compiles without the client.
struct VitrinkaGlance<Row> {
    static var topLimit: Int { 3 }

    let needsYou: Int
    let overdue: Int
    let dueNow: Int
    let inProgress: Int
    /// Σ open questions on boards a live session is listening to.
    let openQuestions: Int
    /// Needs you › overdue › due now, at most `topLimit`.
    let top: [Row]
    /// Attention summed over the other workspaces; nil when there is none.
    let elsewhere: Int?

    init(today: [Row], reason: (Row) -> String, liveQuestions: [Int], elsewhere: [[Row]]) {
        let reasons = today.map(reason)
        needsYou = reasons.filter { $0 == VitrinkaReason.needsYou }.count
        overdue = reasons.filter { $0 == VitrinkaReason.overdue }.count
        dueNow = reasons.filter { $0 == VitrinkaReason.dueNow }.count
        inProgress = reasons.filter { $0 == VitrinkaReason.inProgress }.count
        openQuestions = liveQuestions.reduce(0, +)
        top = Array(VitrinkaReason.attention.flatMap { rank in today.filter { reason($0) == rank } }
            .prefix(Self.topLimit))
        let away = elsewhere.reduce(0) { sum, rows in
            sum + rows.filter { VitrinkaReason.attention.contains(reason($0)) }.count
        }
        self.elsewhere = away > 0 ? away : nil
    }
}
