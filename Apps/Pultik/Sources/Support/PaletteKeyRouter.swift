import AppKit

/// One app-wide keyDown monitor, owned by whichever panel view is on screen.
///
/// The palette needs ↑/↓/↵ *before* the focused NSTextField's field editor eats
/// them, which rules out SwiftUI's `onKeyPress` on an ancestor and leaves a
/// local NSEvent monitor. Installing that monitor per view invites a leak: the
/// panel is rebuilt on every open, and a stale monitor still holding a dead
/// view's `@State` would consume arrows meant for the live one. So there is
/// exactly one monitor for the app's lifetime and a single swappable handler —
/// the newest view always wins, and a late teardown can't unseat it (the token
/// has to match).
@MainActor
final class PaletteKeyRouter {
    static let shared = PaletteKeyRouter()

    private var monitor: Any?
    private var handler: ((NSEvent) -> NSEvent?)?
    private var owner: UUID?

    private init() {}

    /// Take over key handling. Returns nothing — the caller keeps its token and
    /// hands it back to `resign`.
    func claim(_ token: UUID, handler: @escaping (NSEvent) -> NSEvent?) {
        owner = token
        self.handler = handler
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                PaletteKeyRouter.shared.route(event)
            }
        }
    }

    func route(_ event: NSEvent) -> NSEvent? {
        guard let handler else { return event }
        return handler(event)
    }

    /// Release only if still the owner — a disappearing view must not clear the
    /// handler a newly appeared one just installed.
    func resign(_ token: UUID) {
        guard owner == token else { return }
        owner = nil
        handler = nil
    }
}
