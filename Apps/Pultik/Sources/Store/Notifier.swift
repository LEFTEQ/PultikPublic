import AppKit
import Foundation
import UserNotifications

enum Notifier {
    /// A notification whose click opens the panel with the Firing rail
    /// unfolded, rather than a web page. A URL string so it rides FocusGate's
    /// persisted queue unchanged.
    static let firingPanelURL = "pultik://panel/firing"

    /// A prod notification's click: the panel on the `.h` matrix with this
    /// deployment expanded (AppDelegate.showProd).
    static func prodPanelURL(_ key: String) -> String {
        "pultik://panel/prod/\(key)"
    }

    typealias Interruption = NotificationContent.Interruption

    static func requestPermission() {
        UNUserNotificationCenter.current().delegate = ClickHandler.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameters:
    ///   - thread: groups related notifications (one thread per deployment).
    ///   - bypassFocus: deliver now even while FocusGate holds — a prod
    ///     red is exactly what a Focus hold must not sit on.
    static func send(title: String, body: String, url: String?, thread: String? = nil,
                     interruption: Interruption = .active, bypassFocus: Bool = false) {
        Task { @MainActor in
            // Focus hold: queued instead of delivered while a Focus is on
            // (opt-in, Integrations → Focus). The queue is persisted, so a
            // caller that stamps its own "announced" ledger stays honest
            // across a quit. FocusGate flushes on lift.
            if !bypassFocus, FocusGate.shared.holdIfNeeded(title: title, body: body, url: url) { return }
            let content = NotificationContent.make(title: title, body: body, url: url, thread: thread,
                                                   interruption: interruption)
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { _ in }
        }
    }

    /// Where a click goes: `pultik://panel/<rail>` opens the panel on that
    /// rail, any other `url` opens in the browser. Also lets a notification
    /// show while the panel holds focus — the moment a critical is most
    /// likely to be looked at.
    private final class ClickHandler: NSObject, UNUserNotificationCenterDelegate {
        static let shared = ClickHandler()

        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions
        {
            [.banner, .list, .sound]
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    didReceive response: UNNotificationResponse) async
        {
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
                  let string = response.notification.request.content.userInfo["url"] as? String,
                  let url = URL(string: string)
            else { return }
            await MainActor.run {
                let path = url.pathComponents // ["/", "prod", "<key>"]
                if url.scheme == "pultik", url.host() == "panel", path.count == 3, path[1] == "prod" {
                    AppDelegate.shared?.showProd(key: path[2])
                } else if url.scheme == "pultik", url.host() == "panel" {
                    AppDelegate.shared?.showPanel(unfolding: url.lastPathComponent)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
