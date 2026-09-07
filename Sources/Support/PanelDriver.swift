#if DEBUG
import AppKit
import Foundation

/// Debug-only remote control for verifying the panel without touching the
/// user's mouse, keyboard or focus.
///
/// `tools/panel-drive.sh` posts a distributed notification; this turns it
/// into the same state changes and key routing a real summon, keystroke or
/// paste would produce, and can write the panel's own window to a PNG. It
/// compiles into Debug builds only, so the shipped app has no such listener.
///
/// Commands (userInfo `cmd`): `open`, `close`, `query` (`text`), `key`
/// (`key` = enter|tab|up|down|left|right|esc, `mods` = comma list of
/// cmd|opt|shift|ctrl), `capture` (`path` → PNG), `state` (`path` → JSON of
/// the palette state the view reports).
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
        case "capture":
            guard let path = info["path"] else { return }
            app.debugCapturePanel(to: path)
        case "metrics":
            guard let path = info["path"] else { return }
            app.debugWriteMetrics(to: path)
        case "query", "key", "state":
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

    /// Writes `window` as a PNG. Own-window capture needs no screen-recording
    /// grant, which is the whole reason this is in-process.
    static func capture(window: NSWindow, to path: String) {
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]
        ) else {
            NSLog("pultik: debug capture failed for window %d", id)
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(filePath: path))
        } catch {
            NSLog("pultik: debug capture could not write %@: %@", path, error.localizedDescription)
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
