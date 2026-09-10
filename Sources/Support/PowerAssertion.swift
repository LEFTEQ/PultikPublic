import Foundation
import IOKit.pwr_mgt

/// Keeps this Mac awake *and unlocked* (docs/specs/2026-09-10-never-sleep-decisions.md).
///
/// Two public IOKit calls, the same ones `caffeinate` makes, so no helper and
/// no subprocess: a `PreventUserIdleDisplaySleep` assertion (which implies
/// system sleep) and a periodic `IOPMAssertionDeclareUserActivity`, because
/// the screen saver runs on the idle clock the assertion does not touch and
/// the lock fires minutes after either. Lid-close sleep is out of reach
/// without root and is not attempted.
///
/// Stateless apart from the assertion id; `AwakeStore` decides when.
enum PowerAssertion {
    private static let name = "Pultík Never Sleep" as CFString
    private static var assertion: IOPMAssertionID = 0
    private static var activity: IOPMAssertionID = 0
    private static var pulse: Timer?

    /// Roughly a fifth of the shortest screen-saver delay System Settings
    /// offers (one minute), so the idle clock never gets near it.
    private static let pulseSeconds: TimeInterval = 12

    static var isHeld: Bool { assertion != 0 }

    /// Returns false when IOKit refuses — skipped, never raised.
    @discardableResult
    static func hold() -> Bool {
        guard assertion == 0 else { return true }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
        guard status == kIOReturnSuccess else {
            NSLog("pultik: power assertion refused (%d) — Never Sleep unavailable", status)
            return false
        }
        assertion = id
        declareActivity()
        let timer = Timer(timeInterval: pulseSeconds, repeats: true) { _ in declareActivity() }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        pulse = timer
        return true
    }

    static func release() {
        pulse?.invalidate()
        pulse = nil
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    private static func declareActivity() {
        IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &activity)
    }
}
