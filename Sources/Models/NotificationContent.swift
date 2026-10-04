import Foundation
import UserNotifications

/// What one notification carries, built without sending it — so the
/// interruption level, sound, thread and click URL are testable
/// (brief AC9). `Notifier.send` only adds delivery and the Focus hold.
enum NotificationContent {
    /// How hard a notification may interrupt. `.timeSensitive` breaks
    /// through a Focus only in a release signed with the Time Sensitive
    /// entitlement (tools/dist-macos.sh); elsewhere it degrades to `.active`.
    enum Interruption: Equatable {
        case passive, active, timeSensitive

        var level: UNNotificationInterruptionLevel {
            switch self {
            case .passive: .passive
            case .active: .active
            case .timeSensitive: .timeSensitive
            }
        }
    }

    static func make(title: String, body: String, url: String?, thread: String? = nil,
                     interruption: Interruption = .active) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = interruption == .passive ? nil : .default
        content.interruptionLevel = interruption.level
        if let thread { content.threadIdentifier = thread }
        if let url { content.userInfo = ["url": url] }
        return content
    }
}
