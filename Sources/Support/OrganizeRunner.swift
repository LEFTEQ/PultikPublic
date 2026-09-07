import Foundation

/// Bridge to the Hammerspoon `.organize` workspace engine (hammerspoon/
/// organize.lua in this repo, installed by `pultik install --hammerspoon`).
/// Pultík does no window management of its own — the palette only shells out
/// to the `hs` CLI, which hs.ipc provides once Hammerspoon is running.
enum OrganizeRunner {
    /// Runs a layout by name. Blocking work happens off the main actor; the
    /// result comes back as a palette notice — a missing or broken hs must
    /// degrade to an inline line, never a modal (repo rule: unreachable
    /// backends stay quiet).
    static func run(layout: String) async -> SlashResult {
        guard let hs = locateHS() else {
            return .failed("hs CLI not found — install Hammerspoon and enable hs.ipc")
        }
        // The name lands inside a Lua single-quoted literal. It comes from
        // settings.json keys, which a hand edit can make arbitrary — escape
        // rather than trust.
        let escaped = layout
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let code = "Organize.run('\(escaped)')"

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hs)
            process.arguments = ["-c", code]
            let stderr = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return SlashResult.failed("hs failed: \(error.localizedDescription)")
            }
            guard process.terminationStatus == 0 else {
                let detail = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return SlashResult.failed(
                    detail.isEmpty ? "hs exited \(process.terminationStatus) — is Hammerspoon running?" : detail)
            }
            return SlashResult.ok("organized — \(layout)")
        }.value
    }

    /// A GUI app inherits no shell PATH, so homebrew's bin is checked
    /// explicitly — same reasoning as GHToken's gh lookup.
    private static func locateHS() -> String? {
        let candidates = [
            "/opt/homebrew/bin/hs",
            "/usr/local/bin/hs",
            NSHomeDirectory() + "/.local/bin/hs",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Layout names for the `.organize` palette page, read fresh from
/// settings.json on every call: the file is written by the Settings UI but
/// also edited by hand and read by the Lua engine, so a cached copy could
/// show layouts that no longer exist. Raw JSONSerialization keeps the read
/// tolerant — an unmodeled or partial `workspaces` section still lists.
enum WorkspaceLayouts {
    static func names() -> [String] {
        guard let data = try? Data(contentsOf: Preferences.fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = root["workspaces"] as? [String: Any],
              let layouts = workspaces["layouts"] as? [String: Any],
              !layouts.isEmpty
        else {
            // No config yet — the Lua engine ships a built-in "default".
            return ["default"]
        }
        // "default" first (it is what bare ↵ runs), the rest alphabetical.
        return layouts.keys.sorted { a, b in
            if a == "default" { return true }
            if b == "default" { return false }
            return a < b
        }
    }
}
