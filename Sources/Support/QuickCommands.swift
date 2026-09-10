import AppKit

/// Palette quick commands — instant launchers the palette surfaces while
/// typing. Matching is substring-on-keywords; Enter runs the first match
/// (commands win over ask-eve).
struct QuickCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let keywords: [String]
    let run: @MainActor () -> Void

    /// Computed, not stored: the display presets are one entry each and are
    /// edited in Settings ▸ Displays, so `BrightnessStore` is read at match time.
    @MainActor
    static var all: [QuickCommand] {
        fixed + displayPresets
    }

    /// Shared aliases every preset answers to, so `screen` lists them all.
    private static let presetKeywords = ["brightness", "display", "displays", "monitor", "monitors", "screen"]

    @MainActor
    private static var displayPresets: [QuickCommand] {
        let store = BrightnessStore.shared
        return store.presets.enumerated().map { index, preset in
            let nightShift: String? = switch preset.nightShift {
            case .on: "Night Shift on"
            case .off: "Night Shift off"
            case .keep: nil
            }
            return QuickCommand(
                id: "preset:\(index)",
                title: "Displays: \(preset.name)",
                subtitle: ([" every display to \(preset.brightness)%"] + [nightShift].compactMap { $0 })
                    .joined(separator: " · ").trimmingCharacters(in: .whitespaces),
                systemImage: preset.brightness <= 30 ? "moon.fill" : "sun.max",
                keywords: [preset.name.lowercased()] + presetKeywords,
                run: { store.apply(index: index) }
            )
        }
    }

    @MainActor
    private static var fixed: [QuickCommand] {
        let awake = AwakeStore.shared
        return [
            // Never Sleep (spec 2026-09-10 decision 4): one command that
            // toggles; the title says which way. "sleep" is a keyword so
            // typing what you want to allow again also finds it.
            QuickCommand(
                id: "awake",
                title: awake.isAwake ? "Never Sleep: off" : "Never Sleep: on",
                subtitle: awake.isAwake
                    ? "let the Mac sleep and lock again"
                    : "keep this Mac running and unlocked (lid close still sleeps)",
                systemImage: awake.isAwake ? "cup.and.saucer.fill" : "cup.and.saucer",
                keywords: ["awake", "never sleep", "caffeine", "sleep", "amphetamine", "lock"],
                run: { awake.toggle() }
            ),
            // Screens off (decision 2): brightness 0 everywhere, never display
            // sleep — that is what starts the lock timer.
            QuickCommand(
                id: "screens-off",
                title: "Screens off",
                subtitle: "every display and the keyboard to 0% — mouse or ⌥Space wakes",
                systemImage: "display.trianglebadge.exclamationmark",
                keywords: ["screens off", "off", "dark", "black", "blackout", "displays off", "screen off"],
                run: { BrightnessStore.shared.blackout() }
            ),
            QuickCommand(
                id: "vitrinka",
                title: "Open Vitrinka",
                subtitle: "boards & screenshots",
                systemImage: "photo.on.rectangle.angled",
                keywords: ["vitrinka", "board", "boards"],
                run: { openVitrinka() }
            ),
            QuickCommand(
                id: "eve-console",
                title: "Open eve console",
                subtitle: "sessions & approvals",
                systemImage: "sparkles",
                keywords: ["eve", "console", "sessions"],
                run: { open(url: "https://eve.ops.example.invalid") }
            ),
            QuickCommand(
                id: "settings",
                title: "Pultík Settings",
                subtitle: "pins, login item",
                systemImage: "gearshape",
                keywords: ["settings", "preferences", "pins"],
                run: { AppDelegate.shared?.openSettings() }
            ),
        ]
    }

    @MainActor
    static func matching(_ query: String) -> [QuickCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        // Names (the first keyword) outrank shared aliases: "bright" must
        // land on the Bright preset, not on Dim via "brightness".
        let hits = all.filter { cmd in
            cmd.keywords.contains { $0.hasPrefix(q) || $0.contains(q) }
        }
        return hits.filter { $0.keywords.first?.hasPrefix(q) == true }
            + hits.filter { $0.keywords.first?.hasPrefix(q) != true }
    }

    /// The native app when installed (instant), the web app otherwise.
    @MainActor
    private static func openVitrinka() {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/Vitrinka.app"),
            URL(filePath: "/Applications/Vitrinka.app"),
        ]
        if let app = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else {
            open(url: "https://boards.example.invalid")
        }
    }

    @MainActor
    private static func open(url: String) {
        if let parsed = URL(string: url) {
            NSWorkspace.shared.open(parsed)
        }
    }
}
