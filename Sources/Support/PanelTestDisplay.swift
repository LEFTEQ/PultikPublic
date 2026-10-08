#if DEBUG
import Foundation

/// Screen-name policy shared by the native test driver and delayed test launch.
/// A missing Studio Display leaves the ordinary focused-screen fallback intact.
/// `PULTIK_TEST_DISPLAY=<screen name>` picks another screen — a landscape
/// panel on a desk whose Studio Display stands portrait.
enum PanelTestDisplay {
    static func preferredIndex(in names: [String],
                               override: String? = ProcessInfo.processInfo.environment["PULTIK_TEST_DISPLAY"]) -> Int? {
        if let override, let index = names.firstIndex(of: override) { return index }
        return names.firstIndex { $0 == "Studio Display" || $0 == "Apple Studio Display" }
    }
}
#endif
