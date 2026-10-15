#if DEBUG
import Foundation

/// Where a test summon draws: the screen Toolkit's `qa` display role resolves
/// to (`toolkit displays resolve --role qa --app pultik`; the preference lives
/// in `displays.roles.qa` / `displays.apps.pultik` of
/// `~/.config/toolkit/config.json`; Toolkit itself falls back to the menu-bar
/// display). `panel-drive.sh open` passes it per call; a launch takes it as
/// `-ToolkitScreen <name>`. A preference, never a gate: a name that is not
/// connected, or none, leaves the focused-screen fallback.
enum PanelTestDisplay {
    /// The launch's `-ToolkitScreen <name>`, from the argument domain only —
    /// Pultík keeps nothing in `UserDefaults`.
    static var launchScreen: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["ToolkitScreen"] as? String
    }

    static func preferredIndex(in names: [String], wanted: String?) -> Int? {
        guard let wanted, !wanted.isEmpty else { return nil }
        return names.firstIndex(of: wanted)
    }
}
#endif
