#if DEBUG
import AppKit
import Foundation
import ScreenCaptureKit

/// Debug-only remote control for verifying the panel without touching the
/// user's mouse, keyboard or focus.
///
/// `tools/panel-drive.sh` posts a distributed notification; this turns it
/// into the same state changes and key routing a real summon, keystroke or
/// paste would produce, and can write the panel's own window to a PNG. It
/// compiles into Debug builds only, so the shipped app has no such listener.
///
/// Commands (userInfo `cmd`): `open`, `close`, `size` (`text` = WxH, empty
/// resets), `query` (`text`), `paste`
/// (the clipboard through the field editor), `key`
/// (`key` = enter|tab|up|down|left|right|esc|backspace|1–9|i|v, `mods` = comma
/// list of cmd|opt|shift|ctrl), `capture` (`path` → PNG), `state` (`path` → JSON of
/// the palette state the view reports), `firing` (`text` = comma list of
/// made-up alert names, `warning:Name` for a warning, empty clears).
@MainActor
enum PanelDriver {
    static let channel = Notification.Name("dev.example.pultik.debug")
    /// In-process relay to the palette view, which owns the state.
    static let paletteNotification = Notification.Name("dev.example.pultik.debug.palette")

    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: channel, object: nil, queue: .main
        ) { note in
            let info = (note.userInfo ?? [:]).reduce(into: [String: String]()) { out, pair in
                if let key = pair.key as? String, let value = pair.value as? String { out[key] = value }
            }
            MainActor.assumeIsolated { handle(info) }
        }
        NSLog("pultik: debug panel driver listening on %@", channel.rawValue)
    }

    private static func handle(_ info: [String: String]) {
        guard let app = AppDelegate.shared else { return }
        switch info["cmd"] {
        case "open":
            app.debugShowPanel()
        case "close":
            app.closePanel()
        case "size":
            // `WxH` pins the frame (an empty text returns to the screen's
            // own); the summon re-applies it and re-centres the panel.
            let parts = (info["text"] ?? "").split(separator: "x").compactMap { Double($0) }
            PanelMetrics.shared.debugSize = parts.count == 2 ? NSSize(width: parts[0], height: parts[1]) : nil
            app.debugShowPanel()
        case "capture":
            guard let path = info["path"] else { return }
            app.debugCapturePanel(to: path)
        case "metrics":
            guard let path = info["path"] else { return }
            app.debugWriteMetrics(to: path)
        case "firing":
            StatusStore.shared.debugSetFiring(info["text"] ?? "")
        case "github-pause":
            ProbeGate.shared.failed(.github, .unreachable("Debug verification pause"))
        case "github-resume":
            ProbeGate.shared.succeeded(.github)
        case "home-style":
            // The Settings pane's own setter, so AC6 checks what Settings does.
            guard let style = info["text"].flatMap(HomeStyle.init(rawValue:)) else { return }
            StatusStore.shared.setHomeStyle(style)
        case "query", "key", "paste", "state", "clear-preview", "clear-action", "mac-stop", "home-toggle", "mark":
            NotificationCenter.default.post(name: paletteNotification, object: nil, userInfo: info)
        default:
            NSLog("pultik: debug driver ignored %@", String(describing: info))
        }
    }

    /// A keyDown event shaped like the one the field editor would have seen.
    static func keyEvent(named name: String, mods: String?) -> NSEvent? {
        let (code, chars): (UInt16, String)
        switch name {
        case "enter": (code, chars) = (36, "\r")
        case "tab": (code, chars) = (48, "\t")
        case "up": (code, chars) = (126, "")
        case "down": (code, chars) = (125, "")
        case "left": (code, chars) = (123, "")
        case "right": (code, chars) = (124, "")
        case "esc": (code, chars) = (53, "\u{1b}")
        case "v": (code, chars) = (9, "v")
        case "i": (code, chars) = (34, "i") // ⌘I: the detail's inspector
        case "r": (code, chars) = (15, "r") // ⌘R: CI's Re-run failed
        case "a": (code, chars) = (0, "a") // ⌘A: mark every row shown (bulk D1)
        case "backspace": (code, chars) = (51, "\u{7f}")
        // ANSI key codes of the top-row digits — ⌘1–9 switch modules.
        case "1": (code, chars) = (18, "1")
        case "2": (code, chars) = (19, "2")
        case "3": (code, chars) = (20, "3")
        case "4": (code, chars) = (21, "4")
        case "5": (code, chars) = (23, "5")
        case "6": (code, chars) = (22, "6")
        case "7": (code, chars) = (26, "7")
        case "8": (code, chars) = (28, "8")
        case "9": (code, chars) = (25, "9")
        default: return nil
        }
        var flags: NSEvent.ModifierFlags = []
        for mod in (mods ?? "").split(separator: ",") {
            switch mod.trimmingCharacters(in: .whitespaces) {
            case "cmd": flags.insert(.command)
            case "opt", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code
        )
    }

    /// Writes `window` as a PNG. The current process's own shareable content
    /// needs no screen-recording grant, which is the whole reason this is
    /// in-process (`CGWindowListCreateImage` is gone from the macOS 26 SDK).
    /// `also` windows are composited with it, over their union.
    static func capture(window: NSWindow, also: [NSWindow] = [], to path: String) {
        let id = CGWindowID(window.windowNumber)
        let ids = Set(([window] + also).map { CGWindowID($0.windowNumber) })
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.currentProcess
                let windows = content.windows.filter { ids.contains($0.windowID) }
                guard let main = windows.first(where: { $0.windowID == id }) else {
                    NSLog("pultik: debug capture found no shareable window %d", id)
                    return
                }
                let config = SCStreamConfiguration()
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let filter: SCContentFilter
                if windows.count == 1 {
                    filter = SCContentFilter(desktopIndependentWindow: main)
                } else {
                    let union = windows.map(\.frame).reduce(main.frame) { $0.union($1) }
                    guard let display = content.displays.first(where: { $0.frame.intersects(main.frame) })
                        ?? content.displays.first else { return }
                    filter = SCContentFilter(display: display, including: windows)
                    config.sourceRect = union.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                }
                let rect = windows.count == 1 ? filter.contentRect : config.sourceRect
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(rect.width * scale)
                config.height = Int(rect.height * scale)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try png.write(to: URL(filePath: path))
            } catch {
                NSLog("pultik: debug capture of window %d failed: %@", id, error.localizedDescription)
            }
        }
    }

    static func write(state: [String: Any], to path: String) {
        do {
            let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(filePath: path))
        } catch {
            NSLog("pultik: debug state could not write %@: %@", path, error.localizedDescription)
        }
    }
}
#endif
