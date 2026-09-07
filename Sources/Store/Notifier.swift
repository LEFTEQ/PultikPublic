import Foundation
import UserNotifications

enum Notifier {
    static func requestPermission() {
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
}
