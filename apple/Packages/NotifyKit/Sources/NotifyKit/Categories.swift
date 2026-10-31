import Foundation
import PushCrypto
import UserNotifications

/// The notification categories the app registers (docs/PUSH.md §3, §5). Pushes and local
/// notifications use the same identifiers, so one action handler serves both.
public enum NotificationCategories {
    /// An agent asks to run something: Approve, Deny, Open.
    public static let approval = PushKind.approval.categoryIdentifier
    /// An agent waits in the terminal (a question, a menu): Open.
    public static let blocked = PushKind.blocked.categoryIdentifier
    /// An agent finished or failed: Open.
    public static let agentDone = PushKind.done.categoryIdentifier
    /// A long command finished while nobody looked: Open.
    public static let commandDone = PushKind.command.categoryIdentifier

    /// Approve and Deny need Face ID / the passcode before the handler runs (a locked phone
    /// must not approve `rm -rf`); Deny is destructive; Open brings the app forward.
    public static var all: Set<UNNotificationCategory> {
        let approve = UNNotificationAction(
            identifier: PushAction.approve, title: "Approve", options: [.authenticationRequired],
            icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(
            identifier: PushAction.deny, title: "Deny", options: [.authenticationRequired, .destructive],
            icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let open = UNNotificationAction(
            identifier: PushAction.open, title: "Open", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "terminal"))
        return [
            UNNotificationCategory(
                identifier: approval, actions: [approve, deny, open], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: "An agent needs approval", options: [.hiddenPreviewsShowTitle]),
            UNNotificationCategory(
                identifier: blocked, actions: [open], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: "An agent is waiting for you", options: []),
            UNNotificationCategory(identifier: agentDone, actions: [open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: commandDone, actions: [open], intentIdentifiers: [], options: []),
            DeviceNotifications.notificationCategory,
        ]
    }
}

/// Which kinds of notification the user wants (Settings ▸ Notifications). The same choices go
/// to every daemon as `PushPrefs` when push is registered, and gate local notifications.
public struct NotificationPrefs: Codable, Equatable, Sendable {
    public var approvals = true
    public var blocked = true
    public var done = true
    public var failed = true
    public var commands = true
    /// Local notifications only while the app is in the background (never over the terminal
    /// the user is looking at).
    public var onlyInBackground = true

    public init() {}

    public func allows(_ kind: PushKind) -> Bool {
        switch kind {
        case .approval: approvals
        case .blocked: blocked
        case .done: done
        case .failed: failed
        case .command: commands
        }
    }

    static let key = "notification-prefs"

    /// Loads from `defaults` (the app group's when the extension needs them too).
    public static func load(from defaults: UserDefaults = .standard) -> NotificationPrefs {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(NotificationPrefs.self, from: data)
        else { return NotificationPrefs() }
        return prefs
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
