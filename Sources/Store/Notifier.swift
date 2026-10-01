import AppKit
import Foundation
import UserNotifications

enum Notifier {
    /// A notification whose click opens the panel with the Firing rail
    /// unfolded, rather than a web page. A URL string so it rides FocusGate's
    /// persisted queue unchanged.
    static let firingPanelURL = "pultik://panel/firing"

    static func requestPermission() {
        UNUserNotificationCenter.current().delegate = ClickHandler.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String, url: String?) {
        Task { @MainActor in
            // Focus hold: queued instead of delivered while a Focus is on
            // (opt-in, Integrations → Focus). The queue is persisted, so a
            // caller that stamps its own "announced" ledger stays honest
            // across a quit. FocusGate flushes on lift.
            if FocusGate.shared.holdIfNeeded(title: title, body: body, url: url) { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let url { content.userInfo = ["url": url] }
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
                if url.scheme == "pultik", url.host() == "panel" {
                    AppDelegate.shared?.showPanel(unfolding: url.lastPathComponent)
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
