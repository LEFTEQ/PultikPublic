import AppKit
import SwiftUI

/// Show/hide lifecycle signal for the warm panel.
///
/// The panel is retained between quick summons and released after an idle
/// grace period. `onAppear`/`onDisappear` therefore do not fire on every
/// open; views drive their per-open work off this instead: `generation` bumps
/// on every present, `isPresented` drops on dismiss.
@MainActor
@Observable
final class PanelSession {
    private(set) var isPresented = false
    /// Bumped on every present — `.onChange(of: generation)` is the per-open hook.
    private(set) var generation = 0

    func markPresented() {
        generation += 1
        isPresented = true
    }

    func markDismissed() {
        isPresented = false
    }
}

/// How tall the panel is allowed to grow, for the screen it is about to
/// appear on.
///
/// The panel sizes itself to its SwiftUI content, and until 2026-08-29 nothing
/// bounded that: a long right rail (services + reminders + runners + alerts)
/// made the window taller than the display, and since a content resize keeps
/// the top edge pinned and extends downward, the overflow fell off the bottom
/// of the screen with no way to reach it. The columns read this budget and cap
/// themselves so their content scrolls instead of growing; `StatusPanel`
/// clamps the window to it as a backstop, so no future content bug can put the
/// panel off-screen again.
@MainActor
@Observable
final class PanelMetrics {
    static let shared = PanelMetrics()
    /// Breathing room between the panel and the edges of the working area.
    static let margin: CGFloat = 8

    /// Tallest the window may become. Seeded for a small laptop display so the
    /// prewarm pass before any screen is known can never measure unbounded.
    private(set) var maxHeight: CGFloat = 720
    /// Widest the window may become. The three-column panel (680 + 280 + 280)
    /// outgrows scaled laptop displays; the columns read this to fold the
    /// devbox rail before the window would overhang the screen edge.
    private(set) var maxWidth: CGFloat = 1000

    /// Re-read the working area of `screen` (its frame minus menu bar and Dock).
    func update(for screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let height = max(360, screen.visibleFrame.height - Self.margin * 2)
        if abs(height - maxHeight) >= 1 { maxHeight = height }
        let width = max(680, screen.visibleFrame.width - Self.margin * 2)
        if abs(width - maxWidth) >= 1 { maxWidth = width }
    }
}

/// Borderless floating panel anchored under the status item — the wide-menu
/// look NSPopover can't do (no arrow, full-bleed vibrancy, rounded corners).
/// Nonactivating so opening it never steals focus from the frontmost app.
///
/// Warm between quick summons: created on demand and reused across summons —
/// `close()` here means "order out", never "destroy". The expensive part of a
/// summon was constructing + first-layouting the whole SwiftUI tree; keeping
/// the window alive turns ⌥Space into a plain order-front.
@MainActor
final class StatusPanel: NSPanel {
    private var clickMonitor: Any?
    /// The app that had focus before the panel took key — key focus does NOT
    /// return to it on its own when a nonactivating key panel closes (the
    /// "can't type anywhere after dismissing pultík" bug); we hand it back.
    private var previousApp: NSRunningApplication?
    /// The panel is TOP-pinned like Spotlight: when SwiftUI content grows or
    /// shrinks the window resizes from its bottom edge, never by moving the
    /// search bar. AppKit anchors windows bottom-left, so we re-pin on resize.
    /// Centered summon pins top-CENTER (width changes too when rails load);
    /// the status-item drop pins top-left.
    private enum Pin {
        case topLeft(NSPoint)
        case topCenter(NSPoint)
    }
    private var pin: Pin?
    /// The screen the pin was computed against — a content-driven resize has to
    /// re-clamp against the same working area, and `self.screen` is unreliable
    /// while the window is off-screen or mid-move.
    private var pinScreen: NSScreen?
    private var isPinning = false
    private var hostingController: NSViewController!
    private var sizeObservation: NSKeyValueObservation?
    /// Content size waiting to be applied on the next runloop turn.
    private var pendingSize: NSSize?
    var onClose: (() -> Void)?

    private var debugKeepsPanelOpen: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PULTIK_KEEP_PANEL_OPEN"] == "1"
        #else
        false
        #endif
    }

    init(rootView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle]
        #if DEBUG
        if ProcessInfo.processInfo.environment["PULTIK_KEEP_PANEL_OPEN"] == "1" {
            // `.transient` orders a panel out when another app activates even
            // when `hidesOnDeactivate` is false. Captures need to coexist with
            // the user's foreground work, so Debug verification opts out.
            collectionBehavior = [.ignoresCycle]
        }
        #endif
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        // The panel is reused across summons — `close()` must only order out.
        // (AppKit's default for programmatic windows would release it.)
        isReleasedWhenClosed = false

        // The window follows the content's ideal size — but NOT via AppKit's
        // contentViewController auto-sizing. That path resizes the window
        // synchronously from inside SwiftUI's render/layout pass
        // (`NSHostingView.updateAnimatedWindowSize` → `_setFrameCommon` →
        // layout → render → …), and with enough height churn (eve streaming
        // 2026-07-27, the sticky strips 2026-07-28) the constraint engine
        // overruns the main thread's stack (`___chkstk_darwin` in
        // `NSISEngine`, SIGSEGV). So the hosting controller sits inside a
        // plain container — invisible to the auto-sizing machinery — and we
        // observe its preferredContentSize ourselves, applying the resize on
        // the NEXT runloop turn, outside whatever layout pass produced it.
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = [.preferredContentSize]
        let container = NSViewController()
        container.view = NSView()
        container.addChild(hosting)
        container.view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ])
        contentViewController = container
        hostingController = hosting
        sizeObservation = hosting.observe(\.preferredContentSize) { [weak self] controller, _ in
            let size = controller.preferredContentSize
            Task { @MainActor in self?.scheduleResize(to: size) }
        }
    }

    /// Coalesces size updates and applies the newest one asynchronously —
    /// the resize itself re-triggers preferredContentSize churn less this way,
    /// and it can never land inside the layout pass that requested it.
    private func scheduleResize(to size: NSSize) {
        guard size.width > 0, size.height > 0 else { return }
        let alreadyScheduled = pendingSize != nil
        pendingSize = clampedToScreen(size)
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let size = self.pendingSize else { return }
            self.pendingSize = nil
            var target = self.frame
            guard abs(target.width - size.width) >= 0.5
                || abs(target.height - size.height) >= 0.5 else { return }
            // Resize from the bottom edge: the top (search bar) stays put.
            target.origin.y = target.maxY - size.height
            target.size = size
            self.setFrame(target, display: true)
            self.applyPin()
        }
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func resignKey() {
        super.resignKey()
        if !debugKeepsPanelOpen { close() }
    }

    /// Show below the status item button, trailing-aligned, clamped to the screen.
    func show(under button: NSStatusBarButton) {
        guard let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        pinScreen = screen
        PanelMetrics.shared.update(for: screen)
        applyInitialSize()
        let size = frame.size
        let buttonFrame = buttonWindow.frame
        var x = buttonFrame.midX - size.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        pin = .topLeft(NSPoint(x: x, y: buttonFrame.minY - 6))
        applyPin()
        present()
    }

    /// Spotlight-style: horizontally centered on the focused screen, top at
    /// ~20% down. `NSScreen.main` is the screen holding the key window — the
    /// one the user is working on — falling back to the mouse's screen.
    func showCentered() {
        let screen = NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let screen else { return }
        pinScreen = screen
        PanelMetrics.shared.update(for: screen)
        applyInitialSize()
        let vf = screen.visibleFrame
        pin = .topCenter(NSPoint(x: vf.midX, y: vf.maxY - vf.height * 0.20))
        applyPin()
        present()
    }

    /// Run the first layout while the newly created panel is still hidden.
    /// Subsequent warm summons only re-measure the existing tree.
    func prewarm() {
        PanelMetrics.shared.update(for: NSScreen.main)
        applyInitialSize()
    }

    /// Drop both hosting references and the AppKit content after the idle
    /// grace period. AppDelegate creates a fresh panel on the next summon.
    func discardContent() {
        guard !isVisible else { return }
        sizeObservation = nil
        pendingSize = nil
        contentViewController = nil
        hostingController = nil
        contentView = nil
    }

    /// Presentation: the container hides the content from AppKit's
    /// auto-sizing, so the opening size is measured here — synchronously is
    /// fine, nothing is mid-layout before the window is on screen.
    private func applyInitialSize() {
        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        setContentSize(clampedToScreen(size))
    }

    /// The window never exceeds the working area of the screen it is on. The
    /// columns cap themselves to the same budget so their content scrolls; this
    /// is the backstop for anything that doesn't.
    private func clampedToScreen(_ size: NSSize) -> NSSize {
        NSSize(width: min(size.width, PanelMetrics.shared.maxWidth),
               height: min(size.height, PanelMetrics.shared.maxHeight))
    }

    /// Re-assert the top pin after any content-driven resize.
    ///
    /// Both guards below exist because this runs from `didResizeNotification`
    /// and itself moves the window: SwiftUI resizes the hosting view from
    /// inside the window's own layout pass (`NSHostingView.updateAnimatedWindowSize`
    /// → `_setFrameCommon` → layout → render → …), so an unguarded re-pin feeds
    /// that cycle. It ran away while eve was streaming a reply — every token
    /// changed the height — until Auto Layout's constraint engine blew the main
    /// thread's stack (`___chkstk_darwin` inside `NSISEngine`, SIGSEGV
    /// 2026-07-27 09:20).
    private func applyPin() {
        guard !isPinning else { return }
        var target: NSPoint
        switch pin {
        case .topLeft(let point):
            target = point
        case .topCenter(let point):
            target = NSPoint(x: point.x - frame.width / 2, y: point.y)
        case nil:
            return
        }
        // A tall panel slides UP rather than off the bottom edge: the centered
        // summon's top sits 20% down the screen, which is not room enough for a
        // full-height hub. Height is already clamped to the working area, so
        // the lower bound can never rise above the menu bar.
        if let vf = (pinScreen ?? NSScreen.main)?.visibleFrame {
            let lowestTop = vf.minY + PanelMetrics.margin + frame.height
            target.y = min(max(target.y, lowestTop), vf.maxY)
            // Same backstop horizontally: width is clamped to the working
            // area, so keeping the left edge on-screen keeps all of it
            // on-screen. The max runs last — a panel at the width limit
            // prefers its leading edge visible.
            target.x = max(min(target.x, vf.maxX - PanelMetrics.margin - frame.width),
                           vf.minX + PanelMetrics.margin)
        }
        // A no-op move still posts didResize, which lands back here.
        let current = NSPoint(x: frame.minX, y: frame.maxY)
        guard abs(current.x - target.x) >= 0.5 || abs(current.y - target.y) >= 0.5 else { return }
        isPinning = true
        setFrameTopLeftPoint(target)
        isPinning = false
    }

    private func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        makeKeyAndOrderFront(nil)

        // A nonactivating panel doesn't reliably resign key when the user clicks
        // into another app's window — watch global clicks and dismiss ourselves.
        if !debugKeepsPanelOpen {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
        }
    }

    override func close() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        let restore = previousApp
        previousApp = nil
        super.close()
        onClose?()
        // Hand key focus back to whoever had it; skip when the user is
        // switching apps by click (the clicked app is already taking over).
        guard let restore, restore.bundleIdentifier != Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == restore.processIdentifier
        else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: restore)
            restore.activate()
        } else {
            restore.activate(options: .activateIgnoringOtherApps)
        }
    }
}
