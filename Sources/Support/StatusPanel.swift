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

    /// The panel's one frame (panel Home D4, 2026-10-07): 80% of the working
    /// area's height, and 80% of its width clamped to 1240–1600 pt — never
    /// past the working area. The root view takes exactly this size, so
    /// content no longer resizes the window; Home's tiles flex to fill it.
    private(set) var panelSize = NSSize(width: 1240, height: 720)
    static let heightShare: CGFloat = 0.8
    static let widthShare: CGFloat = 0.8
    static let widthRange: ClosedRange<CGFloat> = 1240...1600

    /// Re-read the working area of `screen` (its frame minus menu bar and Dock).
    func update(for screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let height = max(360, screen.visibleFrame.height - Self.margin * 2)
        if abs(height - maxHeight) >= 1 { maxHeight = height }
        let width = max(680, screen.visibleFrame.width - Self.margin * 2)
        if abs(width - maxWidth) >= 1 { maxWidth = width }
        let size = Self.panelSize(for: screen.visibleFrame.size, maxWidth: width, maxHeight: height)
        if abs(size.width - panelSize.width) >= 1 || abs(size.height - panelSize.height) >= 1 {
            panelSize = size
        }
    }

    static func panelSize(for working: NSSize, maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
        let width = min(max(working.width * widthShare, widthRange.lowerBound), widthRange.upperBound)
        return NSSize(width: min(width, maxWidth).rounded(),
                      height: min(working.height * heightShare, maxHeight).rounded())
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
            // Already that size — AppKit may have resized it first, top-left
            // fixed — but it still has to sit where the pin says.
            guard abs(target.width - size.width) >= 0.5
                || abs(target.height - size.height) >= 0.5 else { self.applyPin(); return }
            // Resize from the bottom edge: the top (search bar) stays put.
            target.origin.y = target.maxY - size.height
            target.size = size
            self.setFrame(target, display: true)
            self.applyPin()
            self.refreshShadow()
        }
    }

    /// The window server draws the shadow AND macOS 26's light rim from the
    /// content's alpha as it stood when the shadow was last computed. A
    /// resize can capture the rounded glass before SwiftUI has redrawn it
    /// at the new size — a square rim around the rounded edge (2026-10-07).
    /// Recompute once the new size has rendered.
    private func refreshShadow() {
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
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
    /// 10% down, so the 80%-high panel sits centred in the working area.
    /// `NSScreen.main` is the screen holding the key window — the
    /// one the user is working on — falling back to the mouse's screen.
    /// Native test summons can supply a preferred screen explicitly.
    func showCentered(on preferredScreen: NSScreen? = nil) {
        let screen = preferredScreen ?? NSScreen.main
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.screens.first
        guard let screen else { return }
        pinScreen = screen
        PanelMetrics.shared.update(for: screen)
        applyInitialSize()
        let vf = screen.visibleFrame
        pin = .topCenter(NSPoint(x: vf.midX, y: vf.maxY - vf.height * (1 - PanelMetrics.heightShare) / 2))
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

    /// Every frame write passes the backstop, whoever makes it. The window
    /// was seen resized past both writers above — top-left fixed, unclamped,
    /// never re-pinned (2026-09-23: 1265pt on a 1215pt working area, still at
    /// the x of a 960pt-wide pin, its footer under the Dock) — most likely
    /// AppKit sizing it from the hosting view's required edge pins inside its
    /// own layout pass. Pure on purpose: the rect is capped and placed
    /// from `pin` exactly as `applyPin` would place it, so this never starts
    /// a second frame change for a layout pass to feed on (the 2026-07-27
    /// NSISEngine overflow). No pin yet (prewarm) → capped, not placed.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(constrainedToWorkingArea(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(constrainedToWorkingArea(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func constrainedToWorkingArea(_ rect: NSRect) -> NSRect {
        let size = clampedToScreen(rect.size)
        guard let topLeft = pinnedTopLeft(for: size) else {
            return NSRect(x: rect.minX, y: rect.maxY - size.height, width: size.width, height: size.height)
        }
        return NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    /// Where the pin puts a window of `size`, kept inside the working area.
    private func pinnedTopLeft(for size: NSSize) -> NSPoint? {
        var target: NSPoint
        switch pin {
        case .topLeft(let point):
            target = point
        case .topCenter(let point):
            target = NSPoint(x: point.x - size.width / 2, y: point.y)
        case nil:
            return nil
        }
        // A tall panel slides UP rather than off the bottom edge: the centered
        // summon's top sits 20% down the screen, which is not room enough for a
        // full-height hub. Height is already clamped to the working area, so
        // the lower bound can never rise above the menu bar.
        if let vf = (pinScreen ?? NSScreen.main)?.visibleFrame {
            let lowestTop = vf.minY + PanelMetrics.margin + size.height
            target.y = min(max(target.y, lowestTop), vf.maxY)
            // Same backstop horizontally: width is clamped to the working
            // area, so keeping the left edge on-screen keeps all of it
            // on-screen. The max runs last — a panel at the width limit
            // prefers its leading edge visible.
            target.x = max(min(target.x, vf.maxX - PanelMetrics.margin - size.width),
                           vf.minX + PanelMetrics.margin)
        }
        return target
    }

    /// Re-assert the top pin after any content-driven resize.
    ///
    /// Both guards below date from when this ran from `didResizeNotification`
    /// and itself moved the window: SwiftUI resizes the hosting view from
    /// inside the window's own layout pass (`NSHostingView.updateAnimatedWindowSize`
    /// → `_setFrameCommon` → layout → render → …), so an unguarded re-pin feeds
    /// that cycle. It ran away while eve was streaming a reply — every token
    /// changed the height — until Auto Layout's constraint engine blew the main
    /// thread's stack (`___chkstk_darwin` inside `NSISEngine`, SIGSEGV
    /// 2026-07-27 09:20).
    private func applyPin() {
        guard !isPinning, let target = pinnedTopLeft(for: frame.size) else { return }
        // A no-op move still posts didResize, which lands back here.
        let current = NSPoint(x: frame.minX, y: frame.maxY)
        guard abs(current.x - target.x) >= 0.5 || abs(current.y - target.y) >= 0.5 else { return }
        isPinning = true
        setFrameTopLeftPoint(target)
        isPinning = false
    }

    private func present() {
        // A visible panel was only repositioned; keep its one dismiss monitor.
        guard !isVisible else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        makeKeyAndOrderFront(nil)
        refreshShadow()

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
