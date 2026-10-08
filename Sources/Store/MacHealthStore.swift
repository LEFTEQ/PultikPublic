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

    /// A few KB from the local disk — read inline on main.
    func reread() {
        let next = MacHealthStatus.make(read(), now: now())
        if next != status { status = next }
    }

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
        func named(_ pid: Int) -> String { names[pid].map { "\($0) (\(pid))" } ?? "\(pid)" }
        var reply: Reply?
        if !stdout.isEmpty {
            do {
                reply = try JSONDecoder().decode(Reply.self, from: stdout)
            } catch {
                NSLog("pultik: macwatch stop printed no readable reply — %@", ConfigIssueSink.describe(error))
            }
        }
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
        return await Task.detached(priority: .userInitiated) { execute(resolved, names: names) }.value
    }

    private static func execute(_ argv: [String], names: [Int: String]) -> Outcome {
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
            return .refused("could not start toolkit — \(error.localizedDescription)")
        }
        let (out, err) = ProcessOutput.collect(process, stdout: outPipe, stderr: errPipe)
        return outcome(status: process.terminationStatus, stdout: out,
                       stderr: String(data: err, encoding: .utf8) ?? "", names: names)
    }
}
