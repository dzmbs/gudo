import Foundation
import HostKit
import NotifyKit
import os
import GudoCore
import UserNotifications

/// Where notification requests go: the system center, or a recorder in tests.
protocol NotificationPosting: Sendable {
    func add(_ request: UNNotificationRequest) async throws
}

struct SystemNotificationPoster: NotificationPosting {
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// Owner-only security events as notifications, in front or not (in front they land in
/// Notification Center beside the toast): another device paired with a host, or the host
/// reports something the owner must act on. Tapping opens the host's Devices screen.
@MainActor
final class HostSecurityNotifier {
    private let poster: any NotificationPosting
    private let authorize: () async -> Bool
    private let ledger: HostAlertLedger
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "notify")

    init(poster: any NotificationPosting = SystemNotificationPoster(), ledger: HostAlertLedger = HostAlertLedger(),
         authorize: @escaping () async -> Bool) {
        self.poster = poster
        self.ledger = ledger
        self.authorize = authorize
    }

    func post(_ device: DeviceInfo, hostId: String, hostName: String, session: MultiplayerSession) async {
        guard device.kind == .owner, !session.isThisDevice(device), await authorize() else { return }
        let note = DevicePairedNote(
            hostId: hostId, hostName: hostName, device: device.device,
            deviceName: session.displayName(of: device), pairedAt: device.pairedAt)
        await add(UNNotificationRequest(identifier: DeviceNotifications.identifier(note), content: DeviceNotifications.content(for: note), trigger: nil))
    }

    /// Once per alert per host, across launches (the host repeats it on every connection).
    func post(_ alert: HostAlert, hostId: String, hostName: String) async {
        guard await authorize(), ledger.claim(hostId: hostId, key: alert.key) else { return }
        let note = HostAlertNote(hostId: hostId, hostName: hostName, key: alert.key, title: alert.title, body: alert.body)
        await add(UNNotificationRequest(identifier: DeviceNotifications.identifier(note), content: DeviceNotifications.content(for: note), trigger: nil))
    }

    private func add(_ request: UNNotificationRequest) async {
        do {
            try await poster.add(request)
            Self.log.info("posted \(request.identifier.split(separator: ".").first ?? "", privacy: .public)")
        } catch {
            Self.log.error("posting failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
