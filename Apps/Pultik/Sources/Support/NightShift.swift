import Foundation
import ObjectiveC

/// Night Shift (macOS's blue-light reduction) through Apple's private
/// CoreBrightness framework (docs/specs/2026-09-06-display-presets-decisions.md).
///
/// Why private: there is no public switch for Night Shift; System Settings,
/// `nightlight` and Lunar all go through `CBBlueLightClient`. Resolved at
/// runtime like `DisplayServices`, so a missing class only disables the
/// Night Shift half of a preset — brightness still applies.
///
/// Stateless by design; `BrightnessStore` decides when to call it.
enum NightShift {
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool

    private static let client: AnyObject? = {
        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
            let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        else {
            NSLog("pultik: CoreBrightness unavailable — Night Shift control disabled")
            return nil
        }
        return cls.init()
    }()

    /// The framework loaded and this Mac's panel supports Night Shift.
    static var isAvailable: Bool { client != nil }

    /// Current on/off state, nil when unreadable. Reads the `enabled` flag of
    /// CoreBrightness's `Status` struct (layout: `BOOL active; BOOL enabled; …`);
    /// the buffer is oversized so a future field cannot overflow it.
    static var isEnabled: Bool? {
        guard let client, let imp = implementation(of: "getBlueLightStatus:") else { return nil }
        var status = [UInt8](repeating: 0, count: 128)
        let ok = status.withUnsafeMutableBytes { buffer in
            unsafeBitCast(imp, to: GetStatus.self)(
                client, NSSelectorFromString("getBlueLightStatus:"), buffer.baseAddress!)
        }
        return ok ? status[1] != 0 : nil
    }

    /// Returns false when the framework refuses — skipped, never raised.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let client, let imp = implementation(of: "setEnabled:") else { return false }
        return unsafeBitCast(imp, to: SetEnabled.self)(client, NSSelectorFromString("setEnabled:"), enabled)
    }

    private static func implementation(of selector: String) -> IMP? {
        guard let client, let method = class_getInstanceMethod(type(of: client), NSSelectorFromString(selector))
        else { return nil }
        return method_getImplementation(method)
    }
}
