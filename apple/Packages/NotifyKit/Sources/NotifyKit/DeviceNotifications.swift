import Foundation
import UserNotifications

/// Another owner device paired with a host: every other owner device is told, so a pairing
/// nobody expected is seen and can be removed.
public struct DevicePairedNote: Equatable, Sendable {
    public var hostId: String
    public var hostName: String
    /// Hex key.
    public var device: String
    public var deviceName: String
    public var pairedAt: Date

    public init(hostId: String, hostName: String, device: String, deviceName: String, pairedAt: Date) {
        self.hostId = hostId
        self.hostName = hostName
        self.device = device
        self.deviceName = deviceName
        self.pairedAt = pairedAt
    }
}

/// Something a host says its owner must act on (for example, the grant store was reset).
public struct HostAlertNote: Equatable, Sendable {
    public var hostId: String
    public var hostName: String
    /// Stable across connections (kind and time).
    public var key: String
    public var title: String
    public var body: String

    public init(hostId: String, hostName: String, key: String, title: String, body: String) {
        self.hostId = hostId
        self.hostName = hostName
        self.key = key
        self.title = title
        self.body = body
    }
}

/// Host alerts already notified, kept across launches: a host repeats a standing alert on every
/// connection, and the owner is told once.
public struct HostAlertLedger {
    private let defaults: UserDefaults
    private let storageKey = "notifiedHostAlerts"
    private let limit = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True only the first time an alert is seen for a host.
    public func claim(hostId: String, key: String) -> Bool {
        let entry = "\(hostId)|\(key)"
        var seen = defaults.stringArray(forKey: storageKey) ?? []
        guard !seen.contains(entry) else { return false }
        seen.append(entry)
        defaults.set(Array(seen.suffix(limit)), forKey: storageKey)
        return true
    }
}

public enum DeviceNotifications {
    public static let hostKey = "devicesHost"
    public static let category = "device-paired"
    public static let reviewAction = "review-devices"

    /// One per device, so a repeated event replaces rather than stacks.
    public static func identifier(_ note: DevicePairedNote) -> String {
        "paired.\(note.hostId).\(note.device)"
    }

    public static func content(for note: DevicePairedNote, now: Date = .now, calendar: Calendar = .current) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "New device paired: \(note.deviceName)"
        let time = calendar.isDate(note.pairedAt, inSameDayAs: now)
            ? note.pairedAt.formatted(date: .omitted, time: .shortened)
            : note.pairedAt.formatted(date: .abbreviated, time: .shortened)
        content.body = "Paired with \(note.hostName) at \(time). If this wasn't you, remove it in Settings › Devices."
        content.categoryIdentifier = category
        content.threadIdentifier = "devices.\(note.hostId)"
        // Someone gaining owner access is worth breaking through Focus.
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.userInfo = [hostKey: note.hostId]
        return content
    }

    public static func identifier(_ note: HostAlertNote) -> String {
        "alert.\(note.hostId).\(note.key)"
    }

    public static func content(for note: HostAlertNote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.subtitle = note.hostName
        content.body = note.body
        content.threadIdentifier = "devices.\(note.hostId)"
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.userInfo = [hostKey: note.hostId]
        return content
    }

    public static func hostId(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo[hostKey] as? String
    }

    static var notificationCategory: UNNotificationCategory {
        let review = UNNotificationAction(
            identifier: reviewAction, title: "Review Devices", options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "laptopcomputer.and.iphone"))
        return UNNotificationCategory(
            identifier: category, actions: [review], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "A new device paired with your host", options: [.hiddenPreviewsShowTitle])
    }
}
