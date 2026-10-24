import Foundation
import Observation

/// This Mac's agent sessions (copilot shell WP7): Toolkit's fleet snapshot,
/// `~/.local/state/toolkit/fleet/snapshot.json`, in the generated contract
/// (`FleetContract.swift`, `tools/fleet-contract.sh`). No poller and no
/// network: like `MacHealthStore` it re-reads the file on every panel open
/// and every 15 s while the panel is up, and every read is Now's read of
/// the sessions waiting on you. Missing (fleet not installed) or another
/// contract version hides the Sessions list's fleet section.
@Observable
@MainActor
final class FleetStore {
    static let shared = FleetStore(url: snapshotURL)

    /// A Debug build (never Release) reads `PULTIK_FLEET_SNAPSHOT` instead —
    /// AC 11's fixture (`Tests/Fixtures/fleet-snapshot.json`, its
    /// `generatedAt` refreshed so the read is not stale).
    private static var snapshotURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PULTIK_FLEET_SNAPSHOT"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state/toolkit/fleet/snapshot.json")
    }
    static let rereadInterval: TimeInterval = 15

    private(set) var snapshot: FleetSnapshot?

    @ObservationIgnored private let url: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var lastProblem: String?

    init(url: URL) {
        self.url = url
    }

    /// Balanced with `stopWatching()`.
    func startWatching() {
        holders += 1
        reread()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.rereadInterval, repeats: true) { _ in
            Task { @MainActor in FleetStore.shared.reread() }
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

    func reread() {
        let read = read()
        if read != snapshot { snapshot = read }
        let now = Date()
        let source = NowSource(feed: .fleetSessions, identity: Self.machine)
        let open = Set(NowStore.shared.open(source, now: now).map(\.target.objectID))
        NowStore.shared.record(NowAdapters.sessionsWaiting(read.map { Self.inputs($0, open: open) },
                                                           machine: Self.machine, now: now), now: now)
    }

    /// Older than Now's staleness rule: the publisher stopped, so the rows
    /// are last known, not live.
    func isStale(now: Date = Date()) -> Bool {
        snapshot.map { now.timeIntervalSince($0.generatedAt) > NowAdapters.fleetStaleAfter } ?? true
    }

    /// Runs a fleet verb (`focus`) for a session; failures are logged, the
    /// panel never alerts.
    func focus(_ session: FleetSession) {
        // settings.json `toolkitPath` when set, else `/usr/bin/env toolkit`
        // as always (`ToolkitClient.focusCommand`).
        guard let command = ToolkitClient.focusCommand(["fleet", "focus", "--session", session.sessionId]) else {
            NSLog("pultik: fleet focus %@ — settings.json toolkitPath is not an executable absolute path",
                  session.sessionId)
            return
        }
        Task.detached {
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["PATH": ToolkitClient.focusPATH]) { _, new in new }
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    NSLog("pultik: fleet focus %@ exited %d", session.sessionId, process.terminationStatus)
                }
            } catch {
                NSLog("pultik: fleet focus %@ failed: %@", session.sessionId, error.localizedDescription)
            }
        }
    }

    private static let machine = Host.current().localizedName ?? "this-mac"

    /// Producer diagnostics that mean sessions may be missing or misread.
    private static let coverageLoss: Set<String> = [
        "LIVENESS_UNAVAILABLE", "REGISTRY_FILE_SKIPPED", "REGISTRY_SHAPE_UNKNOWN", "REGISTRY_MISSING",
    ]

    /// A read is complete only when it could have seen every waiting
    /// session: cmux answered, no coverage-loss diagnostic, no waiting
    /// session of unknown liveness, and every session Now still holds open
    /// (`open`, object ids) is listed in some state. The producer hides a
    /// row whose surface lookup failed without saying so, while an answered
    /// session stays listed as busy or idle — a vanished row is unknown,
    /// never handled. An unknown-liveness waiting session stays a need.
    private static func inputs(_ snapshot: FleetSnapshot, open: Set<String>) -> NowInputs.Fleet {
        let listed = Set(snapshot.sessions.map { "session:\($0.sessionId)" })
        let complete = snapshot.cmux.state == .ok
            && !snapshot.diagnostics.contains { coverageLoss.contains($0.code) }
            && !snapshot.sessions.contains { $0.state == .waiting && $0.liveness == .unknown }
            && open.isSubset(of: listed)
        return NowInputs.Fleet(generatedAt: snapshot.generatedAt, complete: complete,
                               sessions: snapshot.sessions.map {
                                   NowInputs.FleetSession(id: $0.sessionId, name: $0.name, project: $0.project,
                                                          waiting: $0.state == .waiting,
                                                          alive: $0.liveness == .alive || $0.liveness == .unknown,
                                                          waitingFor: $0.waitingFor, since: $0.statusSince)
                               })
    }

    private func read() -> FleetSnapshot? {
        do {
            let snapshot = try FleetJSON.decoder().decode(FleetSnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == fleetSnapshotVersion else {
                report("version \(snapshot.version), this build reads \(fleetSnapshotVersion)")
                return nil
            }
            lastProblem = nil
            return snapshot
        } catch CocoaError.fileReadNoSuchFile {
            lastProblem = nil
            return nil
        } catch {
            report(error.localizedDescription)
            return nil
        }
    }

    private func report(_ problem: String) {
        guard problem != lastProblem else { return }
        lastProblem = problem
        NSLog("pultik: fleet snapshot unreadable — %@", problem)
    }
}
