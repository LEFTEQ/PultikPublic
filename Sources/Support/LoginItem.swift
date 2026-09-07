import Foundation
import ServiceManagement

/// Start-at-login, backed by SMAppService (macOS 13+). Registration is stored by
/// the system per app bundle, so it survives rebuilds of the same bundle id.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a human-readable reason on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            NSLog("pultik: login item %@ failed: %@", enabled ? "register" : "unregister", error.localizedDescription)
            return error.localizedDescription
        }
    }
}
