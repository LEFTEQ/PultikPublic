import AppKit
import SwiftUI

/// Pultík's Settings window (decision D8, 2026-08-02).
///
/// Hand-rolled rather than a SwiftUI `Settings` scene. The scene's only
/// supported summons are `SettingsLink` (a View, so unreachable from the
/// AppDelegate where the panel lives) and, before that, the private
/// `showSettingsWindow:` selector — which is precisely what the gear button
/// used to fire into the responder chain and get nothing back from. An
/// `NSWindow` we own can't fail to open, and pultik already owns its status
/// panel this way, so this is the house style rather than an exception.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show() {
        // Single instance: a second click focuses the window that's already
        // up instead of stacking another copy behind it.
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pultík Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false      // we hold the only reference
        window.delegate = self
        window.minSize = NSSize(width: 680, height: 460)
        window.contentView = NSHostingView(rootView: SettingsWindowView(
            store: StatusStore.shared,
            fanStore: FanStore.shared
        ))
        // Remembers position and size across launches, the way a real
        // settings window does. Must come after contentView or the frame
        // gets overwritten by the hosting view's fitting size.
        window.setFrameAutosaveName("pultik.settings")
        window.center()
        self.window = window

        // LSUIElement apps don't come forward on their own.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Drop the reference on close so the next open builds a fresh view tree
    /// (and a fresh FanStore subscription) rather than reviving a stale one.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
