#if DEBUG
/// Screen-name policy shared by the native test driver and delayed test launch.
/// A missing Studio Display leaves the ordinary focused-screen fallback intact.
enum PanelTestDisplay {
    static func preferredIndex(in names: [String]) -> Int? {
        names.firstIndex { $0 == "Studio Display" || $0 == "Apple Studio Display" }
    }
}
#endif
