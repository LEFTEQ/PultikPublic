import AppKit
import SwiftUI

/// Pultík owns its status item directly instead of using SwiftUI's `MenuBarExtra`.
///
/// `MenuBarExtra` routes through Control Center, which persists a per-app
/// "hidden" flag ("NSStatusItem VisibleCC Item-N"). Once that flag flips to 0 —
/// macOS does it on its own when an item is dropped from a crowded menu bar —
/// the icon never comes back, and AppKit terminates the whole app on removal
/// ("StatusBar: 0 terminating on removal"). A hand-made NSStatusItem with
/// `isVisible` forced true is immune to both.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var lastIconState: (AggregateState, Int, Int, Bool, String)?
    /// Warm between quick summons, released after 30 seconds hidden.
    private var panel: StatusPanel?
    private let panelSession = PanelSession()
    private let store = StatusStore.shared
    private var userRequestedQuit = false
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        installSigtermHandler()
        store.onChange = { [weak self] in self?.updateIcon() }
        store.onRefreshComplete = { [weak self] in
            // Run after response decoding locals and autoreleased objects
            // leave scope; only the headless monitor trims between polls.
            DispatchQueue.main.async {
                guard let self, self.panel == nil else { return }
                malloc_zone_pressure_relief(nil, 0)
            }
        }
        TodoStore.shared.onChange = { [weak self] in self?.updateIcon() }
        #if DEBUG
        // A capture launch primes Devbox first so the workspace rail is
        // deterministic; normal Debug and every Release launch are unchanged.
        if debugPanelDelay == nil { store.startPolling() }
        #else
        store.startPolling()
        #endif
        Notifier.requestPermission()
        store.enableLoginItemOnFirstRun()
        // The radar is a background clock, not a Settings feature: touching
        // the singleton here runs its launch tick and arms the daily timer.
        // Reached only through IntegrationRegistry, it would never have run
        // until someone opened Integrations.
        _ = ExpiryRadarStore.shared
        // Same reason: the gate is otherwise reached only by the next
        // notification or by opening Integrations, so anything held when the
        // app last quit would sit in focus-queue.json until something
        // happened to wake it. Touching it here runs its flush-or-arm.
        _ = FocusGate.shared

        HotKey.onPress = { AppDelegate.shared?.togglePanel(nil) }
        HotKey.register(spec: Preferences.load().hotkey)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePanel(_:))
        statusItem = item
        updateIcon()

        // Build the panel on demand. Background monitoring needs no view tree.

        #if DEBUG
        // Remote control for hands-off verification (tools/panel-drive.sh).
        PanelDriver.start()
        // Deterministic native-UI capture without synthesizing a global
        // hotkey. Release builds remain summon-only; UI verification can run
        // the Debug binary with PULTIK_OPEN_PANEL=<delay-seconds> and inspect
        // the real panel after live integrations have had time to refresh.
        // Arm the panel timer BEFORE the targeted Devbox refresh: an offline
        // VM must not turn the documented capture hook into a no-op.
        if let delay = debugPanelDelay {
            Task { [weak self] in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.25, delay)) { [weak self] in
                    self?.togglePanel(nil)
                }
                await self.store.debugRefreshDevbox()
                self.store.startPolling()
            }
        }
        #endif
    }

    #if DEBUG
    private var debugPanelDelay: TimeInterval? {
        ProcessInfo.processInfo.environment["PULTIK_OPEN_PANEL"].flatMap(TimeInterval.init)
    }
    #endif

    // MARK: - Icon

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let iconState = (store.aggregate, TodoStore.shared.openTodos.count,
                         store.unreadAlertCount, store.unreadCriticalAlert,
                         button.effectiveAppearance.name.rawValue)
        if lastIconState.map({ $0 != iconState }) ?? true {
            button.image = MenuBarIconView.render(iconState.0, todoCount: iconState.1,
                                                  alertCount: iconState.2, alertCritical: iconState.3)
            lastIconState = iconState
        }
        // The icon draws the unread count and critical state; the tooltip and
        // a11y label are the only places a VoiceOver user can reach them.
        let unread = store.unreadAlertCount
        let description = unread == 0
            ? "Pultík — command center (⌥Space)"
            : "Pultík — \(unread) unread alert\(unread == 1 ? "" : "s")"
                + "\(store.unreadCriticalAlert ? ", critical" : "") (⌥Space)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
        statusItem?.isVisible = true
    }

    // MARK: - Panel

    /// The panel, building it on demand. The view drives
    /// its per-open lifecycle off `panelSession` (see PanelSession) — the
    /// window's `onClose` is the one funnel every dismiss path (Esc, click
    /// away, resignKey, explicit close) already goes through.
    private func warmPanel() -> StatusPanel {
        if let panel { return panel }
        let panel = StatusPanel(rootView: StatusPanelView(store: store, session: panelSession))
        panel.onClose = { [weak self] in self?.panelDidClose() }
        panel.prewarm()
        self.panel = panel
        return panel
    }

    private func panelDidClose() {
        guard panelSession.isPresented else { return }
        panelSession.markDismissed()
        let generation = panelSession.generation
        // A quick reopening invalidates this release, including when another
        // dismiss happens before the older deadline. No view data is captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.panelSession.isPresented,
                  self.panelSession.generation == generation else { return }
            autoreleasepool {
                self.panel?.discardContent()
                self.panel = nil
            }
            // Return freed view allocations to macOS instead of retaining
            // tens of MiB of empty allocator pages until memory pressure.
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        #endif
        let panel = warmPanel()
        if panel.isVisible {
            panel.close()
            return
        }

        panelSession.markPresented()
        // Status-item click anchors under the item; the ⌥Space summon opens
        // Spotlight-style, centered on the focused screen.
        if sender != nil, let button = statusItem?.button {
            panel.show(under: button)
        } else {
            panel.showCentered()
        }
        #if DEBUG
        debugLastSummonMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        #endif
        Task { await store.refreshIfStale() }
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.close()
    }

    #if DEBUG
    private var debugLastSummonMilliseconds: Double = 0

    /// Available even when the panel is hidden; includes compressed pages.
    func debugWriteMetrics(to path: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            NSLog("pultik: memory metrics failed: %d", result)
            return
        }
        PanelDriver.write(state: [
            "footprintBytes": info.phys_footprint,
            "panelResident": panel != nil,
            "presented": panelSession.isPresented,
            "summonMilliseconds": debugLastSummonMilliseconds,
            "refreshing": store.isRefreshing,
            "todoCount": TodoStore.shared.openTodos.count,
            "inboxCount": store.inbox.count,
        ], to: path)
    }

    /// PanelDriver `open`: the ⌥Space path, without the hotkey.
    func debugShowPanel() {
        guard panel?.isVisible != true else { return }
        togglePanel(nil)
    }

    /// PanelDriver `capture`: the panel's own window to a PNG.
    func debugCapturePanel(to path: String) {
        guard let panel, panel.isVisible else {
            NSLog("pultik: debug capture — panel is not open")
            return
        }
        PanelDriver.capture(window: panel, to: path)
    }
    #endif

    // MARK: - Settings & quit

    /// Pultík owns the Settings window outright (see SettingsWindow). It used
    /// to fire `showSettingsWindow:` into the responder chain to summon the
    /// SwiftUI `Settings` scene — in an LSUIElement app that selector goes
    /// nowhere, so the gear button closed the panel and opened nothing.
    func openSettings() {
        closePanel()
        SettingsWindow.shared.show()
    }

    func quit() {
        userRequestedQuit = true
        NSApplication.shared.terminate(nil)
    }

    /// The always-running promise: nothing but an explicit Quit — not a stray
    /// ⌘Q relayed at the wrong moment, not a scripted `terminate` — takes the
    /// menu bar surface down.
    ///
    /// But SYSTEM termination must always win. Logout, shutdown and restart
    /// deliver a quit Apple event stamped with a `kAEQuitReason` attribute
    /// (kAELogOut / kAEShutDown / kAERestart); refusing it hangs the user's
    /// logout until macOS force-kills us — which lands PAST
    /// `applicationWillTerminate`, so the fan release below never runs and
    /// pinned fans survive the session. Stray ⌘Q and scripted `quit` events
    /// carry no reason attribute, so its mere presence is the
    /// system-initiated signal.
    ///
    /// Ported from Vitrinka Snap (`apps/snap/.../AppDelegate.swift`, commit
    /// 5b0f180b), which found the hole in this guard while copying it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if userRequestedQuit { return .terminateNow }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kCoreEventClass),
           event.eventID == AEEventID(kAEQuitApplication),
           event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return .terminateNow
        }
        return .terminateCancel
    }

    /// AppKit converts SIGTERM into `-terminate:`, so the guard above swallows
    /// `kill -TERM` outright — the process simply survives it. A signal must
    /// mean quit: ignore it at the libc layer and route a dispatch source
    /// through the same `quit()` path, so fans are released exactly as on any
    /// real exit.
    ///
    /// The source listens on a BACKGROUND queue on purpose: the graceful path
    /// needs the main thread, and the main thread can be wedged (Snap sampled
    /// a keychain ACL prompt inside `SecItemCopyMatching` parking launch
    /// itself). SIGTERM has to win anyway, so a 2 s grace window is followed by
    /// a hard exit.
    ///
    /// That fallback deliberately does NOT try to release fans by hand:
    /// `FanStore.releaseAllOnQuit()` is `@MainActor` and ends in a synchronous
    /// SMC write, so calling it from this queue is exactly the wrong move when
    /// the main thread is the thing that is stuck. The helper's own idle
    /// watchdog reverts every hold after 60 s without a client request — that
    /// is the documented backstop for precisely this case.
    private func installSigtermHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler {
            Task { @MainActor in AppDelegate.shared?.quit() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave fans pinned by a controller that no longer exists —
        // the helper's idle watchdog is the backstop, not the plan.
        // `instance`, not `shared`: a run that never touched fan UI must not
        // open AppleSMC (discovery + safe reset) just to tear it down.
        FanStore.instance?.releaseAllOnQuit()
    }
}
