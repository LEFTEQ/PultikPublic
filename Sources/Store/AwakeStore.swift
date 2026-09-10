import Foundation
import Observation

/// Never Sleep (docs/specs/2026-09-10-never-sleep-decisions.md): one switch
/// that keeps this Mac running and authenticated. Persisted as `neverSleep`
/// in settings.json and re-armed at launch, because a `pultik ship` relaunch
/// mid-task must not quietly let the Mac lock. Read by the `awake` quick
/// command, the dock cup and the menu-bar icon.
@Observable
@MainActor
final class AwakeStore {
    static let shared = AwakeStore()

    private(set) var isAwake = false
    /// When the current hold began; nil while off.
    private(set) var since: Date?

    /// The status item redraws off this; set by AppDelegate at launch.
    var onChange: (() -> Void)?

    private init() {
        if Preferences.load().neverSleep == true { arm() }
    }

    func toggle() {
        setAwake(!isAwake)
    }

    func setAwake(_ on: Bool) {
        guard on != isAwake else { return }
        if on { arm() } else { disarm() }
        var prefs = Preferences.load()
        prefs.neverSleep = on ? true : nil
        prefs.save()
        onChange?()
    }

    private func arm() {
        guard PowerAssertion.hold() else { return }
        isAwake = true
        since = Date()
    }

    private func disarm() {
        PowerAssertion.release()
        isAwake = false
        since = nil
    }
}
