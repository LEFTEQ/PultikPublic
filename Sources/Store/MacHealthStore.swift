import Foundation
import Observation

/// The Mac health report as the panel sees it (spec 2026-10-04). No poller
/// and no network: toolkit's `watch serve` publishes the file once a minute,
/// and this re-reads it on every panel open and every 15 s while the panel
/// is up — the same held tick as the fan readout, so a hidden panel reads
/// nothing. A missing file is the quiet case (watch not installed); an
/// unreadable one or another contract version logs once per change and
/// hides like a missing one.
@Observable
@MainActor
final class MacHealthStore {
    static let shared = MacHealthStore(url: MacHealth.defaultURL)
    static let rereadInterval: TimeInterval = 15

    private(set) var status: MacHealthStatus = .hidden

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var lastProblem: String?

    init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
    }

    /// Balanced with `stopWatching()`, like `FanStore.startTicking()`.
    func startWatching() {
        holders += 1
        reread()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.rereadInterval, repeats: true) { _ in
            Task { @MainActor in MacHealthStore.shared.reread() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopWatching() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// A few KB from the local disk — read inline on main. Every read is
    /// Now's read of this Mac's findings too.
    func reread() {
        let health = read()
        let at = now()
        let next = MacHealthStatus.make(health, now: at)
        if next != status { status = next }
        NowStore.shared.record(NowAdapters.macFindings(health.map(NowInputs.MacReport.init), machine: Self.machine,
                                                       now: at), now: at)
    }

    /// This Mac's name in Now's keys: findings belong to the machine that
    /// published them.
    private static let machine = Host.current().localizedName ?? "this-mac"

    private func read() -> MacHealth? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            lastProblem = nil
            return nil
        } catch {
            report("unreadable — \(error.localizedDescription)")
            return nil
        }
        switch MacHealth.decode(data) {
        case let .success(health):
            lastProblem = nil
            return health
        case let .failure(problem):
            report(problem.message)
            return nil
        }
    }

    private func report(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        NSLog("pultik: mac health %@ — %@", url.path, problem)
    }
}

/// Runs a finding's `stop.argv` after the human confirmed it. Never retries:
/// `macwatch stop` re-verifies every process itself, and its answer —
/// stopped, or refused and why — is shown as it came back.
enum MacHealthStop {
    /// A GUI app inherits no shell PATH, so a bare `toolkit` is looked up
    /// where its installers put it: the Homebrew cask, then `~/.local/bin`.
    static let toolkitPaths = [
        "/opt/homebrew/bin/toolkit",
        "/usr/local/bin/toolkit",
        NSHomeDirectory() + "/.local/bin/toolkit",
    ]

    enum Outcome: Equatable, Sendable {
        case stopped(String)
        case refused(String)
    }

    /// argv with argv[0] made absolute. Only `toolkit` (or an absolute path)
    /// is ever run — a bare name the panel cannot place is refused, never
    /// handed to a shell to find.
    static func resolve(_ argv: [String],
                        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> [String]?
    {
        guard let command = argv.first else { return nil }
        if command.hasPrefix("/") { return isExecutable(command) ? argv : nil }
        guard command == "toolkit", let path = toolkitPaths.first(where: isExecutable) else { return nil }
        return [path] + argv.dropFirst()
    }

    /// `macwatch stop --json` (toolkit `internal/macwatch/stop.go`
    /// `StopResult`): which processes ended and on which signal, which were
    /// left alone and why. Go encodes an empty list as null.
    struct Reply: Decodable {
        struct Stopped: Decodable { let pid: Int; let signal: String }
        struct Refused: Decodable { let pid: Int; let reason: String }
        let stopped: [Stopped]?
        let refused: [Refused]?
    }

    /// The reply decides when it parses — any refusal makes the outcome a
    /// refusal, naming what did stop too. Without one, the exit status does,
    /// with stderr as the reason. `names` maps the finding's pids to names.
    static func outcome(status: Int32, stdout: Data, stderr: String, names: [Int: String] = [:]) -> Outcome {
        outcome(reply: decode(stdout), status: status, stderr: stderr, names: names)
    }

    private static func decode(_ stdout: Data) -> Reply? {
        guard !stdout.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(Reply.self, from: stdout)
        } catch {
            NSLog("pultik: macwatch stop printed no readable reply — %@", ConfigIssueSink.describe(error))
            return nil
        }
    }

    private static func outcome(reply: Reply?, status: Int32, stderr: String, names: [Int: String]) -> Outcome {
        func named(_ pid: Int) -> String { names[pid].map { "\($0) (\(pid))" } ?? "\(pid)" }
        let stopped = (reply?.stopped ?? []).map { "\(named($0.pid))\($0.signal == "KILL" ? " after SIGKILL" : "")" }
        let refused = (reply?.refused ?? []).map { "\(named($0.pid)) — \($0.reason)" }
        if !refused.isEmpty {
            let also = stopped.isEmpty ? "" : "; stopped \(stopped.joined(separator: ", "))"
            return .refused(refused.joined(separator: "; ") + also)
        }
        if !stopped.isEmpty { return .stopped("stopped \(stopped.joined(separator: ", "))") }
        let stderrText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0 { return .stopped("stopped") }
        return .refused(stderrText.isEmpty ? "exit \(status)" : stderrText)
    }

    /// Off the main actor: `waitUntilExit` and the pipe reads block.
    static func run(_ argv: [String], names: [Int: String]) async -> Outcome {
        guard let resolved = resolve(argv) else {
            return .refused("toolkit not found — brew install --cask toolkit")
        }
        let exit = await Task.detached(priority: .userInitiated) { execute(resolved) }.value
        return outcome(status: exit.status, stdout: exit.stdout, stderr: exit.stderr, names: names)
    }

    // MARK: - Bulk Stop (bulk actions D4)

    /// One marked finding: its object id, its `stop.argv`, its pids' names.
    struct Target {
        let id: String
        let argv: [String]
        let names: [Int: String]
    }

    /// The `--pid`/`--started` pairs an argv asks for, after its command.
    /// Nil when it is not that shape — it then runs on its own.
    static func pairs(_ argv: [String]) -> (command: [String], pairs: [(pid: String, started: String)])? {
        guard let first = argv.firstIndex(of: "--pid") else { return nil }
        var pairs: [(pid: String, started: String)] = []
        var rest = argv[first...]
        while !rest.isEmpty {
            let pair = Array(rest.prefix(4))
            guard pair.count == 4, pair[0] == "--pid", pair[2] == "--started", Int(pair[1]) != nil else { return nil }
            pairs.append((pair[1], pair[3]))
            rest = rest.dropFirst(4)
        }
        return (Array(argv[..<first]), pairs)
    }

    /// Several findings' argvs as ONE call: their shared command with every
    /// pair, each pid once — toolkit samples the machine once, not once per
    /// finding, and still re-checks every process. Nil when the commands
    /// differ or one is not the expected shape.
    static func combined(_ argvs: [[String]]) -> [String]? {
        var command: [String]?
        var pairs: [(pid: String, started: String)] = []
        for argv in argvs {
            guard let parsed = Self.pairs(argv), command == nil || command == parsed.command else { return nil }
            command = parsed.command
            for pair in parsed.pairs where !pairs.contains(where: { $0.pid == pair.pid }) {
                pairs.append(pair)
            }
        }
        guard let command, !pairs.isEmpty else { return nil }
        return command + pairs.flatMap { ["--pid", $0.pid, "--started", $0.started] }
    }

    /// One combined reply split back per finding: each hears only its own
    /// pids. A reply that does not parse gives every finding the call's own
    /// outcome; a finding the reply never mentions is told so.
    static func outcomes(status: Int32, stdout: Data, stderr: String, targets: [Target]) -> [String: Outcome] {
        let reply = decode(stdout)
        return targets.reduce(into: [:]) { outcomes, target in
            guard let reply else {
                outcomes[target.id] = outcome(reply: nil, status: status, stderr: stderr, names: target.names)
                return
            }
            let pids = Set((pairs(target.argv)?.pairs ?? []).compactMap { Int($0.pid) })
            let own = Reply(stopped: reply.stopped?.filter { pids.contains($0.pid) },
                            refused: reply.refused?.filter { pids.contains($0.pid) })
            outcomes[target.id] = (own.stopped ?? []).isEmpty && (own.refused ?? []).isEmpty
                ? .refused("toolkit did not answer for its processes")
                : outcome(reply: own, status: status, stderr: stderr, names: target.names)
        }
    }

    /// Stops every target: one call per command their argvs share, and a
    /// call of its own for an argv of another shape. Never retried.
    static func run(_ targets: [Target]) async -> [String: Outcome] {
        var groups: [(command: [String], targets: [Target])] = []
        var alone: [Target] = []
        for target in targets {
            guard let command = pairs(target.argv)?.command else {
                alone.append(target)
                continue
            }
            if let index = groups.firstIndex(where: { $0.command == command }) {
                groups[index].targets.append(target)
            } else {
                groups.append((command, [target]))
            }
        }
        var outcomes: [String: Outcome] = [:]
        for group in groups {
            guard let argv = combined(group.targets.map(\.argv)), let resolved = resolve(argv) else {
                for target in group.targets { outcomes[target.id] = .refused("toolkit not found — brew install --cask toolkit") }
                continue
            }
            let exit = await Task.detached(priority: .userInitiated) { execute(resolved) }.value
            outcomes.merge(Self.outcomes(status: exit.status, stdout: exit.stdout, stderr: exit.stderr, targets: group.targets)) { _, new in new }
        }
        for target in alone {
            outcomes[target.id] = await run(target.argv, names: target.names)
        }
        return outcomes
    }

    /// A launch failure reads as a failed exit whose stderr says why.
    private static func execute(_ argv: [String]) -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"] + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"])
            .joined(separator: ":")
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            NSLog("pultik: macwatch stop could not start — %@", error.localizedDescription)
            return (-1, Data(), "could not start toolkit — \(error.localizedDescription)")
        }
        let (out, err) = ProcessOutput.collect(process, stdout: outPipe, stderr: errPipe)
        return (process.terminationStatus, out, String(data: err, encoding: .utf8) ?? "")
    }
}
