import CoreGraphics
import Foundation

/// Brightness of every display this Mac drives, through Apple's private
/// DisplayServices framework (docs/specs/2026-09-04-dim-displays-decisions.md).
///
/// Why private: there is no public API that reaches an Apple external
/// display's backlight — DDC/CI is for third-party monitors and the Studio
/// Display / Pro Display XDR do not speak it. DisplayServices is what the
/// brightness keys, MonitorControl and Lunar use. Resolved with `dlopen` at
/// runtime so a build never links against a framework that Apple could
/// rename; every symbol missing simply makes the feature unavailable.
///
/// Stateless by design. Which displays to touch and what to put back is the
/// `BrightnessStore`'s business.
enum DisplayServices {
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct Bridge {
        let canChange: CanChange
        let get: Get
        let set: Set
    }

    private static let bridge: Bridge? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
            let can = dlsym(handle, "DisplayServicesCanChangeBrightness"),
            let get = dlsym(handle, "DisplayServicesGetBrightness"),
            let set = dlsym(handle, "DisplayServicesSetBrightness")
        else {
            NSLog("pultik: DisplayServices unavailable — display dimming disabled")
            return nil
        }
        return Bridge(
            canChange: unsafeBitCast(can, to: CanChange.self),
            get: unsafeBitCast(get, to: Get.self),
            set: unsafeBitCast(set, to: Set.self))
    }()

    /// Every online display whose backlight this framework can drive.
    /// Virtual displays (Sidecar, AirPlay) answer `false` and are left out.
    static func controllableDisplays() -> [CGDirectDisplayID] {
        guard let bridge else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { bridge.canChange($0) }
    }

    /// 0…1, or nil when the display refuses — a refusal is skipped, never raised.
    static func brightness(of display: CGDirectDisplayID) -> Double? {
        guard let bridge else { return nil }
        var value: Float = 0
        guard bridge.get(display, &value) == 0 else { return nil }
        return Double(value)
    }

    /// Clamps to 0…1. Returns false when the display refuses the write.
    @discardableResult
    static func setBrightness(_ value: Double, of display: CGDirectDisplayID) -> Bool {
        guard let bridge else { return false }
        return bridge.set(display, Float(min(max(value, 0), 1))) == 0
    }
}
