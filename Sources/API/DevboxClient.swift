import AppKit
import Darwin
import Foundation

/// Talks to `devbox` on BuildServer over ssh and reads Mac-side workspace
/// discovery from the local build-server-infra checkout.
///
/// Unlike the other clients this is not HTTP — devbox is a CLI, and the box
/// deliberately holds no credential of its own. Read-only and credential-free
/// actions go over ssh through Pultík's DEDICATED forced-command identity
/// (see `ssh(_:timeout:)`); mutations that may touch git go through the
/// Mac-side `~/bin/devbox`, which mints short-lived GitHub App tokens and
/// sends them for that connection. Pultík is unsandboxed, so Process is
/// available.
///
/// Agent forwarding is deliberately disabled by the guest sshd.
actor DevboxClient {
    static let shared = DevboxClient()

    /// The VM-backed Devbox guest, addressed EXPLICITLY rather than through
    /// the `devops` ~/.ssh/config alias. Bypassing the alias is the point,
    /// not a shortcut: with `IdentitiesOnly=yes` ssh still offers every
    /// identity the matched config block configures, so going through
    /// `devops` would offer the full-shell key alongside the dedicated one
    /// and whichever authenticated first would silently decide whether the
    /// forced-command dispatcher applies. The guest is mesh-only and logs in
    /// as the unprivileged `devbox` user; off the VPN the probe fails fast
    /// and ProbeGate holds it rather than repeatedly hitting sshd.
    private let sshDestination = "devbox@192.0.2.11"
    private let sshPort = "2222"

    /// Pultík's dedicated Devbox identity. Its authorized_keys line on the
    /// guest carries `command=/usr/local/bin/pultik-dispatch,restrict`, so
    /// this key can only run the dispatcher's allowlisted `devbox` verbs —
    /// the dashboard never holds shell-grade access. Interactive attachment
    /// (Warp `devbox shell` / `ws attach`) is a human at a keyboard and
    /// stays on the full-shell `devops` alias in `DevboxLauncher`.
    private nonisolated static var identityPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".ssh/pultik_devbox").path
    }

    // MARK: - Process plumbing

    private struct Result {
        let ok: Bool
        let stdout: String
        let stderr: String
    }

    /// Process pipe readers run concurrently so neither child pipe can fill
    /// while the other is being drained. The box is lock-protected because
    /// Dispatch owns the reader threads, not this actor.
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func set(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Serializes the timeout callback with execute's return path. Cancelling
    /// an already-running DispatchWorkItem does not wait for its body, so a
    /// plain cancellation can otherwise leave PID-signalling work running
    /// after the caller has returned and those numeric PIDs may be reused.
    private final class TimeoutController: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = true

        func fire(_ action: () -> Void) {
            lock.lock()
            guard armed else {
                lock.unlock()
                return
            }
            armed = false
            action()
            lock.unlock()
        }

        /// Acquiring the same lock both disarms a pending callback and waits
        /// for an in-flight callback to finish before execute can return.
        func cancelAndWait() {
            lock.lock()
            armed = false
            lock.unlock()
        }
    }

    private struct CapturedStream {
        let data: Data
        let truncated: Bool
        let error: String?

        static let empty = CapturedStream(data: Data(), truncated: false, error: nil)
    }

    /// A child is untrusted input even when the executable is local. Keep
    /// draining after the retention cap so the child cannot block, but never
    /// let a noisy process grow this menu-bar app without bound.
    private nonisolated static func drain(
        _ handle: FileHandle, retaining limit: Int
    ) -> CapturedStream {
        var data = Data()
        var truncated = false
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                let remaining = max(0, limit - data.count)
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { truncated = true }
            }
            return CapturedStream(data: data, truncated: truncated, error: nil)
        } catch {
            return CapturedStream(data: data, truncated: truncated, error: "\(error)")
        }
    }

    /// libproc gives us the direct children of an already-running Process.
    /// Walk them before signalling the root so descendants cannot be
    /// re-parented out of reach while still holding our pipe writers open.
    private nonisolated static func processTree(root: pid_t) -> [pid_t] {
        guard root > 1 else { return [] }
        var seen = Set<pid_t>()
        var childrenFirst = [pid_t]()

        func visit(_ parent: pid_t) {
            var buffer = [pid_t](repeating: 0, count: 1024)
            let count = buffer.withUnsafeMutableBytes { bytes in
                proc_listchildpids(parent, bytes.baseAddress, Int32(bytes.count))
            }
            guard count > 0 else { return }
            for child in buffer.prefix(Int(count)) where child > 1 && seen.insert(child).inserted {
                visit(child)
                childrenFirst.append(child)
            }
        }

        seen.insert(root)
        visit(root)
        childrenFirst.append(root)
        return childrenFirst
    }

    /// Runs a configured child with bounded wall time and concurrent stdout /
    /// stderr drains. Keeping this primitive shared prevents the fast local
    /// discovery pass from becoming less safe than the network subprocess.
    private func execute(
        _ process: Process, timeout: Int, outputLimit: Int = 4 * 1024 * 1024
    ) -> Result {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() } catch {
            return Result(ok: false, stdout: "", stderr: "\(error)")
        }

        let stdout = LockedBox(CapturedStream.empty)
        let stderr = LockedBox(CapturedStream.empty)
        let timedOut = LockedBox(false)
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.set(Self.drain(out.fileHandleForReading, retaining: outputLimit))
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.set(Self.drain(err.fileHandleForReading, retaining: outputLimit))
            readers.leave()
        }

        let timeoutController = TimeoutController()
        let killer = DispatchWorkItem { [weak process] in
            timeoutController.fire {
                guard let process, process.isRunning else { return }
                timedOut.set(true)
                // Kill this bounded transport subprocess tree synchronously
                // at the deadline: deferring a second signal creates a
                // stale-PID window after this method
                // returns, while TERM cannot guarantee descendants release
                // inherited pipe writers.
                Self.processTree(root: process.processIdentifier)
                    .filter { $0 > 1 }
                    .forEach { Darwin.kill($0, SIGKILL) }
                // A descendant that escaped the tree snapshot still cannot
                // keep this call waiting; a surviving writer receives EPIPE.
                try? out.fileHandleForReading.close()
                try? err.fileHandleForReading.close()
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(timeout), execute: killer
        )

        process.waitUntilExit()
        killer.cancel()
        timeoutController.cancelAndWait()
        readers.wait()

        let capturedOut = stdout.get()
        let capturedErr = stderr.get()
        var errors = [String]()
        let stderrText = String(decoding: capturedErr.data, as: UTF8.self)
        if !stderrText.isEmpty { errors.append(stderrText) }
        if let error = capturedOut.error { errors.append("stdout read failed: \(error)") }
        if let error = capturedErr.error { errors.append("stderr read failed: \(error)") }
        if capturedOut.truncated || capturedErr.truncated {
            errors.append("process output exceeded \(outputLimit) bytes")
        }
        let streamFailed = capturedOut.error != nil || capturedErr.error != nil
            || capturedOut.truncated || capturedErr.truncated
        return Result(
            ok: process.terminationStatus == 0 && !timedOut.get() && !streamFailed,
            // Callers intentionally trust a complete payload over a nonzero
            // exit status. A timed-out/truncated payload is never complete,
            // so withhold it rather than letting that rule accept a prefix.
            stdout: timedOut.get() || streamFailed
                ? ""
                : String(decoding: capturedOut.data, as: UTF8.self),
            stderr: timedOut.get()
                ? "timed out after \(timeout)s" + (errors.isEmpty ? "" : ": \(errors.joined(separator: "; "))")
                : errors.joined(separator: "; ")
        )
    }

    /// One versioned guest document owns runtime truth. Pultík never joins
    /// local manifests into running state.
    private let workspaceSnapshotCommand = "devbox overview --json"

    /// Runs ssh and returns its output. Never throws — every caller here would
    /// only turn a throw straight back into "rail hides", and a menu-bar app
    /// must not surface a modal because a laptop is off the network.
    private func ssh(_ remoteCommand: String, timeout: Int = 15) -> Result {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        var args = [
            // ONLY the dedicated forced-command identity — never the ambient
            // devbox key, never the agent. The dispatcher on the other end is
            // the allowlist; this pair of flags is what guarantees Pultík
            // actually lands on it.
            // A null config keeps ~/.ssh/config out of identity resolution
            // entirely — IdentitiesOnly alone still offers identity files
            // from any matching config block (Host * included).
            "-F", "/dev/null",
            "-i", Self.identityPath,
            "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            // NOT accept-new. This box's key is already pinned in known_hosts,
            // so trust-on-first-use buys nothing and would silently accept
            // whoever answers on 192.0.2.11 if the mesh were ever spoofed. A
            // legitimate host-key rotation should stop Pultík and make the
            // user look, not be waved through by a background poller.
            "-o", "StrictHostKeyChecking=yes",
            // A connection that dies without a TCP reset (sleep, network flap)
            // otherwise leaves ssh reading forever — and refreshDevbox with it.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-p", sshPort,
        ]
        args += [sshDestination, remoteCommand]
        process.arguments = args

        // The keepalives cover dead connections; the shared deadline covers a
        // wedged remote command or an interactive prompt BatchMode missed.
        return execute(process, timeout: timeout)
    }

    /// `devbox ws ls --json` is repo-local and makes no network request. Its
    /// sync paths are facts only this Mac knows, so failure removes local
    /// actions/mesh app links but must not hide the remote workspace rail.
    private func localWorkspaceDiscovery() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executable = home.appending(path: "bin/devbox")
        let infra = home.appending(path: "Work/Projects/example-org/infra/build-server-infra")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: infra.path)
        else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["ws", "ls", "--json"]
        process.currentDirectoryURL = infra
        let result = execute(process, timeout: 5)
        guard result.ok else {
            NSLog("pultik: devbox local workspace discovery failed: %@",
                  result.stderr.isEmpty ? "no output" : result.stderr)
            return nil
        }
        return result.stdout
    }

    /// Runs the Mac-side transport for verbs that may need GitHub access. The
    /// driver owns token minting and passes credentials only for the lifetime
    /// of its SSH connection; Pultík never reads or stores them.
    private func localDevbox(
        _ arguments: [String], timeout: Int, currentDirectory: URL? = nil
    ) -> Result {
        let executable = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "bin/devbox")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return Result(ok: false, stdout: "", stderr: "~/bin/devbox is missing or not executable")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        return execute(process, timeout: timeout)
    }

    // MARK: - Read

    private struct StatusPayload: Codable {
        // Optional like every other hub array/field: Go nil slices marshal
        // to null, and one missing member must never fail the whole decode.
        let generated: Int?
        let projects: [DevboxProject]?
    }

    /// Slot state: running/container counts and per-repo git state.
    ///
    /// Reports failures rather than swallowing them into `[]`: this is the one
    /// probe that speaks to sshd, so a failing poll is a repeated
    /// authentication attempt — the exact pattern fail2ban bans on. The caller
    /// feeds the classification to `ProbeGate`, which stops the polling.
    func status() async -> ProbeResult<[DevboxProject]> {
        let result = ssh("devbox status --json")

        // The PAYLOAD is the verdict, not the exit status. `devbox status`
        // exits 128 on a box with no slots — a git call inside it fails — while
        // printing perfectly good JSON. Gating on `ok` threw that away, blanked
        // the rail, and (once the breaker existed) would have held a perfectly
        // healthy box off for half an hour.
        if let data = result.stdout.data(using: .utf8),
           let payload = try? JSONDecoder().decode(StatusPayload.self, from: data)
        {
            return .value(payload.projects ?? [])
        }

        guard result.ok else {
            // The rail hiding is the designed off-network behavior, but the
            // WHY must land somewhere — a silent [] made "sidebar gone" an
            // undiagnosable mystery.
            let stderr = result.stderr.isEmpty ? "no output" : result.stderr
            NSLog("pultik: devbox status failed: %@", stderr)
            return .failed(Self.classify(stderr))
        }
        // The box answered and we could not read it: our bug or a devbox
        // version skew, not a network fault, so it must never look like a
        // reason to back off from the host. The rail goes empty and the WHY
        // is in the log; the breaker sees a host that answered.
        NSLog("pultik: devbox status returned unreadable output: %@",
              String(result.stdout.prefix(200)))
        return .value([])
    }

    // MARK: - Hub (the rail's one-call feed)

    /// Everything the devbox rail renders, in one ssh round-trip.
    /// `generated` is the BOX-side stamp — nil when no payload carried one,
    /// never fabricated from local time.
    struct Hub {
        let generated: Date?
        let workspaces: [DevboxWorkspace]
        let projects: [DevboxProject]
        let summary: DevboxOverviewSummary
    }

    private struct OverviewResourcesPayload: Codable {
        let cpus: Int
        let load1: Double
        let memoryTotalBytes: Double
        let memoryAvailableBytes: Double
        let swapTotalBytes: Double
        let swapFreeBytes: Double
    }

    private struct OverviewSourcePayload: Codable {
        let app: String
        let path: String
    }

    private struct OverviewServicePayload: Codable {
        let name: String
        let state: String
        let status: String?
        let ports: [String: Int]?
    }

    private struct OverviewWorkspacePayload: Codable {
        let name: String
        let project: String?
        let branch: String?
        let macPath: String?
        let portBase: Int?
        let portCount: Int?
        let created: String?
        let sources: [OverviewSourcePayload]?
        /// Absent on a pre-parking guest, which only ever listed hot rows.
        let state: String?
        let hold: Bool?
        let parkedAt: String?
        let apps: [WorkspaceUnitPayload]?
        let services: [OverviewServicePayload]?
        let memoryBytes: Double?
        let declaredGB: Int?
        let memPeakBytes: Double?
        let drift: String?
    }

    private struct OverviewPayload: Codable {
        let schema: String
        let generated: String
        let capacity: DevboxOverviewCapacity
        let resources: OverviewResourcesPayload
        let workspaces: [OverviewWorkspacePayload]
    }

    private struct HubStackPayload: Codable {
        let composeProject: String
        let cpuPercent: Double
        let memBytes: Double
        /// Optional arrays throughout: the hub verb is Go, and a Go nil slice
        /// marshals to JSON null — today the verb materializes every array,
        /// but a required decode here would blank the ENTIRE rail over a
        /// version skew that dropped one of them.
        let containers: [DevboxContainerStat]?
    }

    private struct HubPayload: Codable {
        let status: StatusPayload
        let stacks: [HubStackPayload]?
        let hosts: [DevboxHost]?
    }

    private struct WorkspaceUnitPayload: Codable {
        let name: String
        let unit: String?
        let active: String?
        let port: Int?
        /// `http://192.0.2.10:<port>` from the box; null for source-only apps.
        let url: String?
    }

    private struct WorkspaceStatePayload: Codable {
        let workspace: String
        let apps: [WorkspaceUnitPayload]?
    }

    private struct WorkspaceMetaPayload: Codable {
        let name: String
        let project: String?
        let branch: String?
        let repo: String?
        let portBase: Int?
        let created: String?
    }

    private struct LocalWorkspaceAppPayload: Codable {
        let name: String
        let port: Int?
        let fqdn: String?
        let sync: String?
    }

    private struct LocalWorkspacePayload: Codable {
        let name: String
        let project: String?
        let portBase: Int?
        let shared: [String]?
        let apps: [LocalWorkspaceAppPayload]?
    }

    /// One remote snapshot: `hub --json` plus ws-v2 unit/meta truth, separated
    /// inside a single ssh process. A local, non-network `ws ls --json` pass
    /// then contributes app ports, FQDNs, and sync paths. The docker-stats pass
    /// inside hub costs ~3–5s wall, which is exactly why it is NOT the probe —
    /// `status()` stays the cheap one-request way back in for the breaker.
    ///
    /// Same payload-is-the-verdict rule as `status()`: exit codes lie.
    func hub() async -> ProbeResult<Hub> {
        let result = ssh(workspaceSnapshotCommand, timeout: 30)
        if let data = result.stdout.data(using: .utf8),
           let payload = try? JSONDecoder().decode(OverviewPayload.self, from: data),
           payload.schema == "devbox.overview/v1"
        {
            let iso = ISO8601DateFormatter()
            let workspaces = payload.workspaces.compactMap { row -> DevboxWorkspace? in
                guard DevboxName.isValid(row.name) else { return nil }
                var apps = (row.apps ?? []).map {
                    DevboxWorkspaceApp(name: $0.name, port: $0.port, fqdn: nil,
                                       syncPath: nil, active: $0.active, hostUp: nil,
                                       remoteURL: $0.url)
                }
                for service in row.services ?? [] {
                    for (name, port) in service.ports ?? [:] {
                        apps.append(DevboxWorkspaceApp(
                            name: name, port: port, fqdn: nil, syncPath: nil,
                            active: service.state == "running" ? "active" : service.state,
                            hostUp: nil
                        ))
                    }
                }
                let stats = (row.services ?? []).map { service in
                    let status = service.status?.isEmpty == false
                        ? service.status!
                        : service.state == "running" ? "Up" : service.state
                    return DevboxContainerStat(name: service.name, cpuPercent: 0,
                                               memBytes: 0, status: status)
                }
                let sources = (row.sources ?? []).compactMap {
                    DevboxName.isValid($0.app) && !$0.path.isEmpty
                        ? DevboxWorkspaceSource(app: $0.app, path: $0.path) : nil
                }
                // `state` is the box's word. A row that omits it comes from a
                // guest that predates parking, where every row was hot; any
                // other value it may grow later ("stopped" is documented as
                // NOT part of the overview) stays visible but is neither hot
                // nor parked, so it can never be mistaken for a live slot.
                let state = row.state ?? "running"
                var macPath: String? = nil
                if let path = row.macPath, !path.isEmpty { macPath = path }
                return DevboxWorkspace(
                    name: row.name, project: row.project, branch: row.branch,
                    portBase: row.portBase, portCount: row.portCount,
                    created: row.created.flatMap(iso.date(from:)),
                    apps: apps.sorted { $0.name < $1.name }, stats: stats,
                    memoryBytes: row.memoryBytes ?? 0, cpuPercent: 0,
                    declaredSources: sources,
                    state: state, hold: row.hold ?? false,
                    parkedAt: row.parkedAt.flatMap(iso.date(from:)),
                    macPath: macPath,
                    declaredGB: row.declaredGB,
                    memPeakBytes: row.memPeakBytes ?? 0,
                    drift: row.drift
                )
            }
            let capacity = payload.capacity
            let resources = payload.resources
            return .value(Hub(
                generated: iso.date(from: payload.generated),
                workspaces: workspaces, projects: [],
                summary: DevboxOverviewSummary(
                    identitySlots: capacity.identitySlots, targetHot: capacity.targetHot,
                    hotCeiling: capacity.hotCeiling ?? capacity.targetHot,
                    claimed: capacity.claimed, running: capacity.running,
                    identities: capacity.identities,
                    parked: capacity.parked ?? 0,
                    floorGB: capacity.floorGB ?? 0,
                    pressureSome: capacity.pressureSome ?? 0,
                    pressureFull: capacity.pressureFull ?? 0,
                    cpus: resources.cpus, load1: resources.load1,
                    memoryTotalBytes: resources.memoryTotalBytes,
                    memoryAvailableBytes: resources.memoryAvailableBytes,
                    swapTotalBytes: resources.swapTotalBytes,
                    swapFreeBytes: resources.swapFreeBytes
                )
            ))
        }

        guard result.ok else {
            let stderr = result.stderr.isEmpty ? "no output" : result.stderr
            NSLog("pultik: devbox hub failed: %@", stderr)
            return .failed(Self.classify(stderr))
        }
        // The host answered, but this composite snapshot is incomplete. It
        // cannot be reported as success because that would replace a valid
        // rail with false empty/stopped state. Treat it as a short transient
        // failure rather than an authentication rejection.
        NSLog("pultik: devbox hub returned unreadable output: %@",
              String(result.stdout.prefix(200)))
        return .failed(.unreachable("invalid devbox workspace snapshot"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Last-wins dictionaries throughout: every key here crosses a process or
    /// machine boundary, so duplicate payload rows must never trap the app.
    private func assembleWorkspaces(
        metas: [WorkspaceMetaPayload],
        states: [WorkspaceStatePayload],
        locals: [LocalWorkspacePayload],
        hosts: [DevboxHost],
        stacks: [HubStackPayload]
    ) -> [DevboxWorkspace] {
        let metaByName = Dictionary(metas.map { ($0.name, $0) },
                                    uniquingKeysWith: { _, latest in latest })
        let stateByName = Dictionary(states.map { ($0.workspace, $0) },
                                     uniquingKeysWith: { _, latest in latest })
        let localByName = Dictionary(locals.map { ($0.name, $0) },
                                     uniquingKeysWith: { _, latest in latest })
        let hostsByWorkspace = Dictionary(grouping: hosts, by: \.workspace)
        let names = Set(metaByName.keys)
            .union(stateByName.keys)
            .union(localByName.keys)
            .union(hostsByWorkspace.keys)
        let stackProjects = stackProjectsByWorkspace(names: names, stacks: stacks)

        let iso = ISO8601DateFormatter()
        var result: [DevboxWorkspace] = []
        for name in names {
            guard DevboxName.isValid(name) else {
                NSLog("pultik: ignoring workspace with unsafe name")
                continue
            }
            let meta = metaByName[name]
            let local = localByName[name]
            let stateApps = Dictionary((stateByName[name]?.apps ?? []).map { ($0.name, $0) },
                                       uniquingKeysWith: { _, latest in latest })
            let localApps = Dictionary((local?.apps ?? []).map { ($0.name, $0) },
                                       uniquingKeysWith: { _, latest in latest })
            let workspaceHosts = hostsByWorkspace[name] ?? []
            let hostByFQDN = Dictionary(workspaceHosts.map { ($0.fqdn, $0) },
                                        uniquingKeysWith: { _, latest in latest })

            var appNames = Set(stateApps.keys).union(localApps.keys)
            var fallbackHosts: [String: DevboxHost] = [:]
            for host in workspaceHosts where !localApps.values.contains(where: { $0.fqdn == host.fqdn }) {
                fallbackHosts[host.label] = host
                appNames.insert(host.label)
            }

            let apps = appNames.sorted().map { appName -> DevboxWorkspaceApp in
                let local = localApps[appName]
                let host = local?.fqdn.flatMap { hostByFQDN[$0] } ?? fallbackHosts[appName]
                return DevboxWorkspaceApp(
                    name: appName,
                    port: local?.port ?? host?.port,
                    fqdn: local?.fqdn ?? host?.fqdn,
                    syncPath: local?.sync,
                    active: stateApps[appName]?.active,
                    hostUp: host?.up
                )
            }

            let project = workspaceProject(
                name: name, declared: meta?.project ?? local?.project,
                stackProjects: stackProjects[name] ?? []
            )
            let ownedStacks: [HubStackPayload]
            if let project {
                let base = "devbox-\(project)-\(name)"
                ownedStacks = stacks.filter {
                    $0.composeProject == base || $0.composeProject == base + "-e2e"
                }
            } else {
                ownedStacks = []
            }
            let stats = ownedStacks.flatMap { $0.containers ?? [] }
                .sorted { $0.name < $1.name }
            result.append(DevboxWorkspace(
                name: name,
                project: project,
                branch: meta?.branch,
                portBase: meta?.portBase ?? local?.portBase,
                created: meta?.created.flatMap(iso.date(from:)),
                apps: apps,
                stats: stats,
                memoryBytes: ownedStacks.reduce(0) { $0 + $1.memBytes },
                cpuPercent: ownedStacks.reduce(0) { $0 + $1.cpuPercent },
                declaredSources: []
            ))
        }
        return result.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Parse every stack against the complete workspace set exactly once.
    /// Longest-name-first prevents `api` from stealing `foo-api`'s stack.
    private func stackProjectsByWorkspace(
        names: Set<String>, stacks: [HubStackPayload]
    ) -> [String: Set<String>] {
        let safeNames = names.filter(DevboxName.isValid).sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        }
        var result: [String: Set<String>] = [:]
        for stack in stacks {
            guard stack.composeProject.hasPrefix("devbox-") else { continue }
            var root = String(stack.composeProject.dropFirst("devbox-".count))
            if root.hasSuffix("-e2e") { root.removeLast("-e2e".count) }
            guard let workspace = safeNames.first(where: { root.hasSuffix("-\($0)") }) else {
                continue
            }
            let project = String(root.dropLast(workspace.count + 1))
            guard DevboxName.isValid(project) else { continue }
            result[workspace, default: []].insert(project)
        }
        return result
    }

    /// Dynamic workspaces declare their project in `.ws-meta`. Committed
    /// workspace manifests currently do not, so their globally parsed compose
    /// ownership is the other exact source. Ambiguity means no attribution.
    private func workspaceProject(
        name: String, declared: String?, stackProjects: Set<String>
    ) -> String? {
        if let declared, DevboxName.isValid(declared) { return declared }
        guard stackProjects.count == 1 else {
            if stackProjects.count > 1 {
                NSLog("pultik: refusing ambiguous stack attribution for workspace %@", name)
            }
            return nil
        }
        return stackProjects.first
    }

    private func assembleRemainingProjects(
        _ input: [DevboxProject], stacks: [HubStackPayload]
    ) -> [DevboxProject] {
        let byStack = Dictionary(stacks.map { ($0.composeProject, $0) },
                                 uniquingKeysWith: { _, latest in latest })
        var projects = input
        for index in projects.indices {
            projects[index].slots = projects[index].slots.filter {
                $0.n == 0 || projects[index].name == "sample-stack"
            }
            for slot in projects[index].slots.indices {
                guard let stack = byStack[projects[index].slots[slot].composeProject] else { continue }
                projects[index].slots[slot].cpuPercent = stack.cpuPercent
                projects[index].slots[slot].memoryBytes = stack.memBytes
                projects[index].slots[slot].stats = stack.containers ?? []
            }
        }
        return projects.filter { !$0.slots.isEmpty }
    }

    /// ssh says why it failed in prose; the two classes need telling apart.
    ///
    /// Anything the server had to authenticate — or a host that no longer
    /// exists, like an ssh alias dropped in a key migration — is `rejected`:
    /// re-trying it every 90 seconds is what earns a ban, and it will not
    /// start working on its own.
    private static func classify(_ stderr: String) -> ProbeFailure {
        let text = stderr.lowercased()
        let rejected = [
            "permission denied",
            "too many authentication failures",
            "no supported authentication",
            "host key verification failed",
            "could not resolve hostname",
            "name or service not known",
            "nodename nor servname",
        ]
        if let hit = rejected.first(where: { text.contains($0) }) {
            return .rejected(hit)
        }
        let firstLine = stderr
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? "ssh failed"
        return .unreachable(firstLine.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Actions

    @discardableResult
    func up(project: String, slug: String?) async -> Bool {
        guard DevboxName.isValid(project) else {
            NSLog("pultik: refusing devbox up — unsafe project name")
            return false
        }
        var arguments = ["up", project]
        if let slug, !slug.isEmpty {
            guard DevboxName.isValid(slug) else {
                NSLog("pultik: refusing devbox up — unsafe slug")
                return false
            }
            arguments.append(slug)
        }
        let result = localDevbox(arguments, timeout: 180)
        if !result.ok {
            NSLog("pultik: devbox up failed: %@",
                  result.stderr.isEmpty ? "no output" : result.stderr)
        }
        return result.ok
    }

    @discardableResult
    func down(project: String, slug: String?) async -> Bool {
        guard let command = DevboxName.command("devbox down", project, slug) else { return false }
        return ssh(command).ok
    }

    // MARK: - ws-v2 lifecycle (park / hold / unhold / up)

    /// Which Mac-side verbs the card may run. `down` and `gc` are deliberately
    /// absent: parking is the reversible stop, and the HUD never offers the
    /// destructive ones. The forced-command dispatcher behind `ssh()` does
    /// not know these verbs, and adding them there would hand the dashboard
    /// key a lifecycle it does not need — the Mac-side driver already owns
    /// `up` for the same reason (it syncs and mints), so the three cheap
    /// verbs ride the same executable.
    enum WorkspaceVerb: String {
        case park, hold, unhold
    }

    /// `devbox park|hold|unhold <ws>`. None of them resolves the cwd; the
    /// driver forwards the verb to the box by name.
    @discardableResult
    func run(_ verb: WorkspaceVerb, workspace: String) async -> Bool {
        guard DevboxName.isValid(workspace) else {
            NSLog("pultik: refusing devbox %@ — unsafe workspace name", verb.rawValue)
            return false
        }
        let result = localDevbox([verb.rawValue, workspace], timeout: 90)
        if !result.ok {
            NSLog("pultik: devbox %@ %@ failed: %@", verb.rawValue, workspace,
                  result.stderr.isEmpty ? "no output" : result.stderr)
        }
        return result.ok
    }

    /// `devbox up <ws>` FROM the workspace's Mac worktree: the driver resolves
    /// the recipe from its cwd and syncs that checkout, so a bare `up` from
    /// anywhere else would revive the wrong thing or nothing. The path is the
    /// overview's `macPath`, validated to an existing directory under $HOME
    /// like every other local path Pultík acts on. Revive is ~16 s; a cold
    /// first start with pulls can take minutes.
    @discardableResult
    func up(workspace: String, macPath: String) async -> Bool {
        guard DevboxName.isValid(workspace) else {
            NSLog("pultik: refusing devbox up — unsafe workspace name")
            return false
        }
        guard let directory = DevboxLauncher.localDirectory(macPath) else {
            NSLog("pultik: refusing devbox up %@ — Mac path unusable", workspace)
            return false
        }
        let result = localDevbox(["up", workspace], timeout: 300, currentDirectory: directory)
        if !result.ok {
            NSLog("pultik: devbox up %@ failed: %@", workspace,
                  result.stderr.isEmpty ? "no output" : result.stderr)
        }
        return result.ok
    }
}

/// Project names and slot slugs arrive in `devbox status --json` — over the
/// network, from a machine — and end up interpolated into shell commands. One
/// of those shells runs on THIS Mac (the Warp launch config), so a crafted
/// payload would be remote JSON turning into local code execution.
///
/// They are VALIDATED, not escaped. Every name devbox mints is
/// `[A-Za-z0-9._-]`, so anything else is refused outright — "quote it
/// cleverly" is the approach that eventually loses.
enum DevboxName {
    static func isValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// "devbox up" + project + optional slug, or nil if either is unsafe.
    static func command(_ verb: String, _ project: String, _ slug: String?) -> String? {
        guard isValid(project) else {
            NSLog("pultik: refusing devbox command — unsafe project name")
            return nil
        }
        guard let slug, !slug.isEmpty else { return "\(verb) \(project)" }
        guard isValid(slug) else {
            NSLog("pultik: refusing devbox command — unsafe slug")
            return nil
        }
        return "\(verb) \(project) \(slug)"
    }
}

// MARK: - Local launchers

/// Actions that run on THIS Mac against a remote slot.
enum DevboxLauncher {
    /// Interactive attachment deliberately KEEPS the full-shell `devops`
    /// alias: a human shell cannot run under the forced-command dispatcher
    /// that `DevboxClient`'s dedicated identity is bound to, and Warp runs
    /// these commands as the user, not as Pultík.
    private static let host = "devops"

    /// Local sync paths come from this Mac's build-server-infra manifests. Keep
    /// every action inside the user's home and require the directory to exist:
    /// stale or edited discovery data must never become an arbitrary file URL.
    /// Pure path validation, so the client actor can gate `devbox up`'s cwd
    /// on the same rule the launchers use. Nothing here touches UI.
    nonisolated static func localDirectory(_ rawPath: String, quiet: Bool = false) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let expanded: String
        if rawPath == "~" {
            expanded = home.path
        } else if rawPath.hasPrefix("~/") {
            expanded = home.appending(path: String(rawPath.dropFirst(2))).path
        } else {
            expanded = rawPath
        }
        let url = URL(filePath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.resolvingSymlinksInPath().path
        guard url.path == homePath || url.path.hasPrefix(homePath + "/") else {
            if !quiet { NSLog("pultik: refusing devbox local path outside home") }
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            // `quiet` is the view's per-render availability check; a missing
            // worktree is a state to render, not an event to log each frame.
            if !quiet { NSLog("pultik: devbox local path is missing or not a directory: %@", url.path) }
            return nil
        }
        return url
    }

    @MainActor
    static func revealLocalPath(_ path: String) {
        guard let url = localDirectory(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    static func openLocalCursor(_ path: String) {
        guard let url = localDirectory(path) else { return }
        let candidates = ["/usr/local/bin/cursor", "/opt/homebrew/bin/cursor"]
        if let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = [url.path]
            do {
                try process.run()
            } catch {
                NSLog("pultik: failed to launch Cursor CLI: %@", "\(error)")
            }
            return
        }
        var target = URLComponents()
        target.scheme = "cursor"
        target.host = "file"
        target.path = url.path
        guard let cursorURL = target.url else {
            NSLog("pultik: failed to build Cursor URL for local workspace")
            return
        }
        NSWorkspace.shared.open(cursorURL)
    }

    @MainActor
    static func copyLocalPath(_ path: String) {
        guard let url = localDirectory(path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(url.path, forType: .string) else {
            NSLog("pultik: failed to copy devbox local path")
            return
        }
    }

    /// Opens the native workspace viewer in Warp. Unlike the legacy tenant
    /// shell launcher, this attaches the whole multi-repo/systemd/Compose unit.
    @MainActor
    static func summonWorkspaceWarp(_ workspace: String) {
        guard DevboxName.isValid(workspace) else {
            NSLog("pultik: refusing Warp workspace with unsafe name")
            return
        }
        let name = "devbox-workspace-\(workspace)"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appending(path: ".warp/launch_configurations")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let yaml = """
            ---
            name: \(name)
            windows:
              - tabs:
                  - layout:
                      cwd: \(home.path)
                      commands:
                        - exec: ssh -t \(host) 'devbox ws attach \(workspace)'
            """
            try yaml.write(to: dir.appending(path: "\(name).yaml"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("pultik: failed to write workspace Warp config: %@", "\(error)")
            return
        }
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "warp://launch/\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens Warp in the slot's tmux session.
    ///
    /// Warp registers the `warp://` scheme but ships no CLI, and its launch
    /// configurations are the only supported way to open a tab running a given
    /// command. So: write the config, then trigger it by URI.
    @MainActor
    static func summonWarp(project: String, slug: String) {
        // This writes a file the terminal will EXECUTE on this Mac, from names
        // the remote box supplied. Nothing unvalidated gets near it.
        guard DevboxName.isValid(project), DevboxName.isValid(slug) else {
            NSLog("pultik: refusing to write a Warp launch config for an unsafe name")
            return
        }
        let name = "devbox-\(project)-\(slug)"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appending(path: ".warp/launch_configurations")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("pultik: failed to create Warp launch-config directory: %@", "\(error)")
            return
        }

        // Shell attachment needs no GitHub credential, so it stays on plain
        // SSH. The guest deliberately refuses agent forwarding.
        let slot = slug == "shared" ? "" : " \(slug)"
        let command = "ssh -t \(host) 'devbox shell \(project)\(slot)'"
        let yaml = """
        ---
        name: \(name)
        windows:
          - tabs:
              - layout:
                  cwd: \(FileManager.default.homeDirectoryForCurrentUser.path)
                  commands:
                    - exec: \(command)
        """
        let file = dir.appending(path: "\(name).yaml")
        do {
            try yaml.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            NSLog("pultik: failed to write Warp launch config: %@", "\(error)")
            return
        }

        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "warp://launch/\(encoded)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The app chip's secondary action: the reachable address on the
    /// clipboard, for pasting into a curl or a teammate's chat. Only a URL
    /// that already passed `DevboxWorkspaceApp.url`'s validation gets here.
    @MainActor
    static func copyURL(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(url.absoluteString, forType: .string) {
            NSLog("pultik: failed to copy devbox app URL")
        }
    }

    /// Opens a guest app directly over the WireGuard mesh. VM-backed workspace
    /// ports are stable at 192.0.2.10; a local SSH tunnel would only add a
    /// detached process and a second failure mode.
    @MainActor
    static func openPortal(port: Int) {
        guard (1 ... 65535).contains(port),
              let url = URL(string: "http://192.0.2.10:\(port)/portal/")
        else {
            NSLog("pultik: refusing invalid devbox app port: %d", port)
            return
        }
        NSWorkspace.shared.open(url)
    }
}
