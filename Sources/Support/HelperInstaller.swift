// Vendored from GenesisFanControl@f43699d (Sources/GenesisFanControlCore/Privileged/HelperInstaller.swift).
// DIVERGED ON PURPOSE (2026-08-01): installs pultik's own daemon from inside
// Pultik.app, and sweeps the GenesisFanControl-era helper on the way in.
//
//  HelperInstaller.swift
//
//  Installs pultik-fan-control-helper by asking for an admin password via
//  osascript, then copying the helper binary into /usr/local/sbin, dropping
//  a launchd plist in /Library/LaunchDaemons, and loading it.
//
//  This is the unsigned-developer path. A production app would do this via
//  SMAppService.daemon(plistName:).register() with a signed bundle carrying
//  the helper at Contents/Library/LaunchDaemons/.
//

import Foundation

enum HelperInstallError: Error, CustomStringConvertible {
    case helperBinaryNotFound(searched: [String])
    case osascript(String)
    case cancelled
    case timeout

    var description: String {
        switch self {
        case .helperBinaryNotFound(let s):
            return "\(HelperConstants.helperBinaryName) not found in the app bundle. Looked in:\n  - \(s.joined(separator: "\n  - "))"
        case .osascript(let s):
            return "Privileged install failed: \(s)"
        case .cancelled:
            return "Install cancelled."
        case .timeout:
            return "The helper was installed but never answered its socket."
        }
    }
}

enum HelperInstaller {
    /// Where the helper binary lives. In a built app it sits next to the app
    /// binary in Contents/MacOS; the env override exists for CI / packaging.
    private static func candidateHelperPaths() -> [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["PULTIK_HELPER_BINARY"] {
            paths.append(env)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
        paths.append(exeDir.appendingPathComponent(HelperConstants.helperBinaryName).path)
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: HelperConstants.helperBinaryName) {
            paths.append(bundled.path)
        }
        return paths
    }

    /// Pops the system password prompt once and runs the install as root.
    /// Returns when the helper socket actually answers.
    static func install() throws {
        let helperBinary = try locateHelperBinary()

        // Stage the helper into a world-readable temp dir first. The app may
        // live somewhere the root shell spawned by osascript cannot read
        // (root holds no TCC grant for ~/Documents or ~/Downloads) — its cp
        // would fail with "Operation not permitted". This process DOES hold
        // the grant, so copy with user privileges and let the privileged
        // script install from the staged path.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pultik-fan-control-install", isDirectory: true)
        let stagedHelper = stagingDir
            .appendingPathComponent(HelperConstants.helperBinaryName)
        try? FileManager.default.removeItem(at: stagingDir)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: helperBinary, toPath: stagedHelper.path)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // Escape every interpolated path the way bash single-quote-bracketed
        // strings expect: `'` → `'\''`. Without this, a username/dev path
        // containing an apostrophe (O'Brien / Martin's MacBook) breaks out of
        // the string and either fails the script or, worse, runs whatever
        // follows as a shell command.
        let helperQ    = shellEscape(stagedHelper.path)
        let installedQ = shellEscape(HelperConstants.installedHelperPath)
        let launchdQ   = shellEscape(HelperConstants.launchDaemonPath)
        let legacyPlistQ  = shellEscape(HelperConstants.Legacy.launchDaemonPath)
        let legacyBinQ    = shellEscape(HelperConstants.Legacy.installedHelperPath)
        let legacySocketQ = shellEscape(HelperConstants.Legacy.socketPath)
        // Label is project-controlled (a Swift string literal) but defend in
        // depth — strip anything the shell could interpret.
        let labelLiteral = HelperConstants.helperLabel
            .replacingOccurrences(of: "'", with: "'\\''")

        let plistXML = launchdPlistContents()
        let script = """
        set -e
        # Sweep the GenesisFanControl-era helper. Two root SMC writers with
        # independent 1 Hz re-assertion loops fight over setpoints, so pultik
        # takes over rather than coexisting.
        launchctl bootout system \(legacyPlistQ) 2>/dev/null || true
        rm -f \(legacyPlistQ)
        rm -f \(legacyBinQ)
        rm -f \(legacySocketQ)
        mkdir -p /usr/local/sbin
        cp \(helperQ) \(installedQ)
        chown root:wheel \(installedQ)
        chmod 755 \(installedQ)
        cat > \(launchdQ) << 'PLIST_EOF'
        \(plistXML)
        PLIST_EOF
        chown root:wheel \(launchdQ)
        chmod 644 \(launchdQ)
        launchctl bootout system \(launchdQ) 2>/dev/null || true
        launchctl bootstrap system \(launchdQ)
        launchctl enable system/\(labelLiteral) 2>/dev/null || true
        launchctl kickstart -k system/\(labelLiteral)
        """

        try runWithAdminPrivileges(script: script)

        // Wait up to 3s for the socket to come up.
        let deadline = Date().addingTimeInterval(3.0)
        let client = HelperClient()
        while Date() < deadline {
            if client.ping() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HelperInstallError.timeout
    }

    /// Uninstall via the same admin prompt. Booting the daemon out makes it
    /// revert every held fan on the way down (its SIGTERM path), so this
    /// can't strand a pinned fan.
    static func uninstall() throws {
        let launchdQ   = shellEscape(HelperConstants.launchDaemonPath)
        let installedQ = shellEscape(HelperConstants.installedHelperPath)
        let socketQ    = shellEscape(HelperConstants.socketPath)
        let script = """
        launchctl bootout system \(launchdQ) 2>/dev/null || true
        rm -f \(launchdQ)
        rm -f \(installedQ)
        rm -f \(socketQ)
        """
        try runWithAdminPrivileges(script: script)
    }

    /// Wrap `s` in single quotes, escaping any embedded `'` as `'\''`.
    /// Result is safe to drop verbatim into a single-quoted bash word.
    private static func shellEscape(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: -

    private static func locateHelperBinary() throws -> String {
        let candidates = candidateHelperPaths()
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw HelperInstallError.helperBinaryNotFound(searched: candidates)
    }

    private static func runWithAdminPrivileges(script: String) throws {
        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(escaped)" with administrator privileges
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]

        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()

        do {
            try task.run()
        } catch {
            throw HelperInstallError.osascript("could not launch osascript: \(error)")
        }
        // Read before waiting — a full pipe buffer would deadlock the wait.
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus != 0 else { return }
        let stderr = String(data: data, encoding: .utf8) ?? ""
        // osascript reports a dismissed password prompt as -128; that's the
        // user saying no, not a failure worth an error banner.
        if stderr.contains("-128") { throw HelperInstallError.cancelled }
        throw HelperInstallError.osascript(
            stderr.isEmpty ? "exit \(task.terminationStatus)" : stderr)
    }

    private static func launchdPlistContents() -> String {
        return #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\#(HelperConstants.helperLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\#(HelperConstants.installedHelperPath)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>StandardOutPath</key>
          <string>\#(HelperConstants.logPath)</string>
          <key>StandardErrorPath</key>
          <string>\#(HelperConstants.errorLogPath)</string>
        </dict>
        </plist>
        """#
    }
}
