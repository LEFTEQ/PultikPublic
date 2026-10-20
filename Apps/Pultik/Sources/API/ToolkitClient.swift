import Foundation

/// Reads `toolkit catalog dashboard --json`, the Toolkit module's one source
/// (vitr:dec/19kqjqz): the local CLI, launched without a shell through
/// `BoundedProcess` — off the main actor, its wall time and output bounded.
/// Read-only (vitr:dec/bctezf0): the panel runs no other verb, so it never
/// launches a workflow, toggles a guard or indexes transcripts.
enum ToolkitClient {
    static let arguments = ["catalog", "dashboard", "--json"]
    static let timeout: TimeInterval = 20
    static let outputLimit = 4 << 20

    /// A GUI app inherits no shell PATH, so `toolkit` is looked up where its
    /// installers put it: the Homebrew cask, then `~/.local/bin`.
    static let installPaths = [
        "/opt/homebrew/bin/toolkit",
        "/usr/local/bin/toolkit",
        NSHomeDirectory() + "/.local/bin/toolkit",
    ]

    /// The binary to run; nil = not installed. A Debug build reads
    /// `PULTIK_TOOLKIT_EXECUTABLE` (an absolute path) first, so native QA can
    /// point it at a provider built in a worktree.
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        #if DEBUG
        if let path = environment["PULTIK_TOOLKIT_EXECUTABLE"], path.hasPrefix("/") {
            return isExecutable(path) ? URL(filePath: path) : nil
        }
        #endif
        return installPaths.first(where: isExecutable).map { URL(filePath: $0) }
    }

    /// One read, detached from the caller's actor: the run blocks.
    static func dashboard(executable: URL) async -> Result<ToolkitDashboard, ToolkitReadFailure> {
        await Task.detached(priority: .utility) { read(executable) }.value
    }

    static func read(_ executable: URL, arguments: [String] = arguments, timeout: TimeInterval = timeout,
                     outputLimit: Int = outputLimit) -> Result<ToolkitDashboard, ToolkitReadFailure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin"]
            + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let output: BoundedProcess.Output
        do {
            output = try BoundedProcess.run(process, timeout: timeout, outputLimit: outputLimit)
        } catch {
            return .failure(.failed("could not start toolkit — \(error.localizedDescription)"))
        }
        return answer(output, timeout: timeout, outputLimit: outputLimit)
    }

    /// Only a whole answer parses: a timed-out, truncated or failed stdout is
    /// never complete, so no prefix of it can read as a dashboard. stderr is
    /// diagnostics only — its overflow is harmless, its read failure is not.
    static func answer(_ output: BoundedProcess.Output, timeout: TimeInterval,
                       outputLimit: Int) -> Result<ToolkitDashboard, ToolkitReadFailure> {
        if output.timedOut { return .failure(.timedOut(seconds: Int(timeout))) }
        if output.stdout.truncated { return .failure(.tooLarge(bytes: outputLimit)) }
        if let error = output.stdout.error ?? output.stderr.error {
            return .failure(.failed("reading toolkit's answer failed — \(error)"))
        }
        guard output.stdout.complete else { return .failure(.timedOut(seconds: Int(timeout))) }
        return parse(status: output.status, stdout: output.stdout.data, stderr: output.stderr.data)
    }

    // MARK: - The answer

    /// The runx envelope (Toolkit `internal/runx`), only what this reads.
    private struct Envelope<Payload: Decodable>: Decodable {
        let ok: Bool?
        let data: Payload?
        let diagnostics: [Diagnostic]?
    }

    private struct Diagnostic: Decodable {
        let code: String?
        let severity: String?
        let detail: String?
        let fix: String?

        var text: String {
            [detail ?? code ?? "toolkit diagnostic", fix.map { "— \($0)" }].compactMap { $0 }.joined(separator: " ")
        }
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    /// A dashboard only from an `ok` envelope and a clean exit: a failed
    /// envelope is a failed read even when it carries data, so the panel
    /// keeps what it held, labelled by its age. Diagnostics the dashboard's
    /// issues do not already name join them. A failure says why: an error
    /// diagnostic, then stderr, then the exit status. An older toolkit prints
    /// its `catalog` help for the unknown verb.
    static func parse(status: Int32, stdout: Data, stderr: Data) -> Result<ToolkitDashboard, ToolkitReadFailure> {
        let decoder = FleetJSON.decoder()
        let errText = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let probe = try? decoder.decode(Envelope<VersionProbe>.self, from: stdout) else {
            let outText = String(decoding: stdout, as: UTF8.self)
            if outText.contains("Available Commands") || errText.contains("unknown command")
                || errText.contains("unknown flag") {
                return .failure(.outdated)
            }
            if status != 0 {
                return .failure(.failed(errText.split(separator: "\n").first.map(String.init) ?? "toolkit exited \(status)"))
            }
            return .failure(.unreadable("not a toolkit envelope"))
        }
        let diagnostics = probe.diagnostics ?? []
        guard probe.ok == true, status == 0, let version = probe.data?.version else {
            let reason = diagnostics.first { $0.severity == "error" }?.text
                ?? errText.split(separator: "\n").first.map(String.init)
                ?? (status == 0 ? "toolkit answered without a dashboard" : "toolkit exited \(status)")
            return .failure(.failed(reason))
        }
        guard version == ToolkitDashboard.supportedVersion else { return .failure(.unsupportedVersion(version)) }
        let dashboard: ToolkitDashboard
        do {
            guard let data = try decoder.decode(Envelope<ToolkitDashboard>.self, from: stdout).data else {
                return .failure(.unreadable("no data"))
            }
            dashboard = data
        } catch {
            return .failure(.unreadable(Self.describe(error)))
        }
        let extra = diagnostics.filter { !dashboard.issues.contains($0.detail ?? "") }.map(\.text)
        guard !extra.isEmpty else { return .success(dashboard) }
        return .success(ToolkitDashboard(version: dashboard.version, generatedAt: dashboard.generatedAt,
                                        release: dashboard.release, indexedAt: dashboard.indexedAt,
                                        inventory: dashboard.inventory, windows: dashboard.windows,
                                        issues: dashboard.issues + extra))
    }

    /// A decoding error by the field it failed on, never the payload.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        let path: (DecodingError.Context) -> String = { context in
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context): return "missing \(path(context)).\(key.stringValue)"
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            return "bad \(path(context))"
        @unknown default: return "undecodable"
        }
    }
}
