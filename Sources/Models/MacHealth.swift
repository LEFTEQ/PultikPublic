import Foundation

/// What on this Mac is probably not needed, and what it costs — the report
/// Toolkit's `toolkit watch serve` publishes to `~/.local/state/toolkit/machine/
/// health.json` every minute (atomic replace). A read-only mirror of contract
/// v1: toolkit owns detection, the headline and the stop verb; the panel only
/// formats and draws (spec 2026-10-04). Go types: toolkit
/// `internal/macwatch/health.go`; golden file
/// `Tests/Fixtures/macwatch-health.json`.
///
/// Foundation-only, like the overview glances: everything a test pins lives
/// here, the store only reads the file and the views only draw.
struct MacHealth: Decodable, Equatable, Sendable {
    /// The one contract version this build reads. Another version hides the
    /// whole feature (and logs once) — never a partial decode.
    static let contractVersion = 1

    static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".local/state/toolkit/machine/health.json")
    }

    let version: Int
    let generatedAt: Date
    /// The span CPU and network rates average over.
    let windowSeconds: Int
    let machine: Machine
    let headline: Headline
    let families: [Family]
    let findings: [Finding]
    let network: Network
    let diagnostics: [Diagnostic]

    /// red · amber · info · ok — the order findings sort and tiles color by.
    enum Severity: String, Decodable, Equatable, Sendable, Comparable {
        case red, amber, info, ok

        private var rank: Int {
            switch self {
            case .red: 0
            case .amber: 1
            case .info: 2
            case .ok: 3
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    struct Machine: Decodable, Equatable, Sendable {
        let cores: Int
        let load1: Double
        /// Of all cores, 0…100.
        let cpuPct: Double
        let memTotalGb: Double
        let memUsedGb: Double
        let compressorGb: Double
        let swapUsedGb: Double
        let swapTotalGb: Double
        let procs: Int
    }

    /// The footer's one line, computed by toolkit — shown verbatim, never
    /// recomputed here. Empty text means nothing is flagged.
    struct Headline: Decodable, Equatable, Sendable {
        let severity: Severity
        let text: String
        let orphans: Int
        let flagged: Int
        let cpuPct: Double
        let memGb: Double
    }

    /// One treemap tile: every process of one executable together.
    struct Family: Decodable, Equatable, Sendable, Identifiable {
        let name: String
        let count: Int
        let memMb: Double
        /// Of one core.
        let cpuPct: Double
        let health: Severity
        let flagged: Int
        var id: String { name }
    }

    struct Finding: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        /// orphan · stale · runaway · network — display only, so a kind this
        /// build has never seen still lists.
        let kind: String
        let severity: Severity
        let title: String
        let detail: String
        let evidence: String
        let family: String
        let project: String?
        let since: Date
        /// Of one core, averaged over the window.
        let cpuPct: Double
        let memMb: Double
        let netOutBps: Double?
        let netInBps: Double?
        let processes: [ProcessRef]
        let stop: Stop

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            severity = try c.decode(Severity.self, forKey: .severity)
            title = try c.decode(String.self, forKey: .title)
            detail = try c.decode(String.self, forKey: .detail)
            evidence = try c.decode(String.self, forKey: .evidence)
            family = try c.decode(String.self, forKey: .family)
            project = try c.decodeIfPresent(String.self, forKey: .project)
            since = try c.decode(Date.self, forKey: .since)
            cpuPct = try c.decode(Double.self, forKey: .cpuPct)
            memMb = try c.decode(Double.self, forKey: .memMb)
            netOutBps = try c.decodeIfPresent(Double.self, forKey: .netOutBps)
            netInBps = try c.decodeIfPresent(Double.self, forKey: .netInBps)
            // Go encodes a nil slice as null.
            processes = try c.decodeIfPresent([ProcessRef].self, forKey: .processes) ?? []
            stop = try c.decode(Stop.self, forKey: .stop)
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, severity, title, detail, evidence, family, project, since, cpuPct, memMb,
                 netOutBps, netInBps, processes, stop
        }
    }

    /// A pid with its start time, so a recycled pid never matches.
    struct ProcessRef: Decodable, Equatable, Sendable {
        let pid: Int
        let started: Date
        let name: String
        let command: String
    }

    /// Whether the finding can be stopped from the panel, and how: `argv` is
    /// run as-is after the human confirms (`macwatch stop` re-verifies every
    /// process first). `reason` says why not when unsupported.
    struct Stop: Decodable, Equatable, Sendable {
        let supported: Bool
        let reason: String?
        let argv: [String]?
    }

    struct Network: Decodable, Equatable, Sendable {
        let top: [Talker]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            top = try c.decodeIfPresent([Talker].self, forKey: .top) ?? []
        }

        private enum CodingKeys: String, CodingKey { case top }
    }

    struct Talker: Decodable, Equatable, Sendable {
        let name: String
        let pid: Int
        let inBps: Double
        let outBps: Double
        /// A VPN process: its bytes are other processes' traffic.
        let tunnel: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            pid = try c.decode(Int.self, forKey: .pid)
            inBps = try c.decode(Double.self, forKey: .inBps)
            outBps = try c.decode(Double.self, forKey: .outBps)
            tunnel = try c.decodeIfPresent(Bool.self, forKey: .tunnel) ?? false
        }

        private enum CodingKeys: String, CodingKey { case name, pid, inBps, outBps, tunnel }
    }

    /// A partial failure the report still stands on.
    struct Diagnostic: Decodable, Equatable, Sendable {
        let code: String
        let detail: String
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        windowSeconds = try c.decode(Int.self, forKey: .windowSeconds)
        machine = try c.decode(Machine.self, forKey: .machine)
        headline = try c.decode(Headline.self, forKey: .headline)
        families = try c.decodeIfPresent([Family].self, forKey: .families) ?? []
        findings = try c.decodeIfPresent([Finding].self, forKey: .findings) ?? []
        network = try c.decode(Network.self, forKey: .network)
        diagnostics = try c.decodeIfPresent([Diagnostic].self, forKey: .diagnostics) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case version, generatedAt, windowSeconds, machine, headline, families, findings, network, diagnostics
    }

    enum ReadError: Error, Equatable {
        /// A contract this build does not read.
        case version(Int)
        case unreadable(String)

        var message: String {
            switch self {
            case let .version(found):
                "contract v\(found), this build reads v\(MacHealth.contractVersion) — hidden until Pultík updates"
            case let .unreadable(why): "unreadable — \(why)"
            }
        }
    }

    /// The version gate runs first, on the version alone: a v2 file must
    /// hide the feature, not half-decode into v1 types.
    static func decode(_ data: Data) -> Result<MacHealth, ReadError> {
        struct Probe: Decodable { let version: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601Flexible
        do {
            let probe = try decoder.decode(Probe.self, from: data)
            guard probe.version == contractVersion else { return .failure(.version(probe.version)) }
            return .success(try decoder.decode(MacHealth.self, from: data))
        } catch {
            return .failure(.unreadable(ConfigIssueSink.describe(error)))
        }
    }

    /// Worst first (red, amber, info), toolkit's order kept within a severity.
    var findingsWorstFirst: [Finding] {
        findings.enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
    }
}

/// What the panel may say about the report right now.
enum MacHealthStatus: Equatable, Sendable {
    /// No file, an unreadable one or another contract version: the chip, the
    /// This Mac dot and the page's data all hide.
    case hidden
    /// `toolkit watch` stopped publishing: the chip hides, the page says so.
    case stale(MacHealth)
    case fresh(MacHealth)

    /// Three missed publishes of a 60 s cadence.
    static let staleAfter: TimeInterval = 180

    static func make(_ health: MacHealth?, now: Date) -> MacHealthStatus {
        guard let health else { return .hidden }
        return now.timeIntervalSince(health.generatedAt) > staleAfter ? .stale(health) : .fresh(health)
    }

    var fresh: MacHealth? {
        if case let .fresh(health) = self { return health }
        return nil
    }

    /// The footer chip: a fresh report with something flagged, else nothing.
    var chip: MacHealthChip? {
        guard let health = fresh, !health.headline.text.isEmpty else { return nil }
        let top = health.findingsWorstFirst.filter { $0.severity != .ok }.prefix(5)
        var lines = top.map { "\(MacHealthFormat.glyph($0.severity)) \($0.title)" }
        if health.findings.count > top.count { lines.append("+\(health.findings.count - top.count) more") }
        return MacHealthChip(severity: health.headline.severity, text: health.headline.text,
                             help: (lines + ["", "Open Mac health — .mac"]).joined(separator: "\n"))
    }
}

struct MacHealthChip: Equatable, Sendable {
    let severity: MacHealth.Severity
    let text: String
    let help: String
}

/// Units as toolkit computes them: memory MB are MiB (RSS KiB / 1024) and
/// GB divide by 1024 again; rates are decimal bytes per second.
enum MacHealthFormat {
    static func memory(mb: Double) -> String {
        mb < 1024 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f GB", mb / 1024)
    }

    static func gigabytes(_ gb: Double) -> String {
        "\(number(gb)) GB"
    }

    /// "93/96 GB", "4.8/6.0 GB".
    static func gigabytes(_ used: Double, of total: Double) -> String {
        "\(number(used))/\(number(total)) GB"
    }

    private static func number(_ gb: Double) -> String {
        String(format: gb < 10 ? "%.1f" : "%.0f", gb)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1000: "\(Int(bytesPerSecond.rounded())) B/s"
        case ..<1_000_000: scaled(bytesPerSecond / 1000, "KB/s")
        default: scaled(bytesPerSecond / 1_000_000, "MB/s")
        }
    }

    private static func scaled(_ value: Double, _ unit: String) -> String {
        String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, unit)
    }

    /// One core's percent: a decimal only where it would otherwise read 0.
    static func cpu(_ percent: Double) -> String {
        String(format: percent < 10 && percent > 0 ? "%.1f%% CPU" : "%.0f%% CPU", percent)
    }

    /// "11.7% CPU · 5.9 GB · ↑ 2.6 MB/s" — the parts a finding actually has.
    static func cost(_ finding: MacHealth.Finding) -> String {
        var parts: [String] = []
        if finding.cpuPct > 0 { parts.append(cpu(finding.cpuPct)) }
        parts.append(memory(mb: finding.memMb))
        if let out = finding.netOutBps, out > 0 { parts.append("↑ \(rate(out))") }
        if let incoming = finding.netInBps, incoming > 0 { parts.append("↓ \(rate(incoming))") }
        return parts.joined(separator: " · ")
    }

    /// The tile's label at its widest: "claude ×82 · 26.8 GB".
    static func tile(_ family: MacHealth.Family) -> String {
        "\(family.name)\(family.count > 1 ? " ×\(family.count)" : "") · \(memory(mb: family.memMb))"
    }

    /// "qemu-system-aarch64 (22504), tail (45691)" — exactly what a stop names.
    static func processes(_ refs: [MacHealth.ProcessRef]) -> String {
        refs.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
    }

    static func glyph(_ severity: MacHealth.Severity) -> String {
        switch severity {
        case .red: "●"
        case .amber: "▲"
        case .info: "○"
        case .ok: "·"
        }
    }
}
