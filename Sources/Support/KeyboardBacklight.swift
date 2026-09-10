import Foundation
import ObjectiveC

/// The keyboard backlight through Apple's private CoreBrightness framework
/// (docs/specs/2026-09-10-never-sleep-decisions.md), the way `NightShift`
/// reaches the blue-light client in the same framework.
///
/// Why private: there is no public API for the keyboard backlight either;
/// `KeyboardBrightnessClient` is what Control Center drives. Resolved at
/// runtime, so a missing class only disables the keyboard half of a preset.
///
/// Stateless by design; `BrightnessStore` decides when to call it.
enum KeyboardBacklight {
    private typealias CopyIDs = @convention(c) (AnyObject, Selector) -> Unmanaged<NSArray>?
    private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let client: AnyObject? = {
        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
            let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else {
            NSLog("pultik: CoreBrightness keyboard client unavailable — keyboard backlight control disabled")
            return nil
        }
        return cls.init()
    }()

    /// The framework loaded and at least one backlit keyboard is attached.
    static var isAvailable: Bool { !keyboards().isEmpty }

    /// Every backlit keyboard's id (the built-in one and any Magic Keyboard
    /// with a backlight). Empty when the class is missing.
    static func keyboards() -> [UInt64] {
        guard let client, let imp = implementation(of: "copyKeyboardBacklightIDs") else { return [] }
        let ids = unsafeBitCast(imp, to: CopyIDs.self)(
            client, NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue()
        return (ids as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    /// 0…1, nil when the keyboard refuses.
    static func brightness(of keyboard: UInt64) -> Double? {
        guard let client, let imp = implementation(of: "brightnessForKeyboard:") else { return nil }
        let value = unsafeBitCast(imp, to: Get.self)(client, NSSelectorFromString("brightnessForKeyboard:"), keyboard)
        return value.isFinite ? Double(value) : nil
    }

    /// Clamps to 0…1. Returns false when the keyboard refuses the write.
    @discardableResult
    static func setBrightness(_ value: Double, of keyboard: UInt64) -> Bool {
        guard let client, let imp = implementation(of: "setBrightness:forKeyboard:") else { return false }
        return unsafeBitCast(imp, to: Set.self)(
            client, NSSelectorFromString("setBrightness:forKeyboard:"), Float(min(max(value, 0), 1)), keyboard)
    }

    private static func implementation(of selector: String) -> IMP? {
        guard let client, let method = class_getInstanceMethod(type(of: client), NSSelectorFromString(selector))
        else { return nil }
        return method_getImplementation(method)
    }
}
