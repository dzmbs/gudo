import Foundation
import PushCrypto
import UserNotifications

public protocol NotificationActionClient: Sendable {
    /// Answers over the host's live connection.
    func decide(hostId: String, paneId: UInt64, requestId: UInt64, optionId: UInt32) async throws
    /// Answers on a one-shot connection signed with the device key; `daemonId` picks the saved
    /// ticket.
    func sendPushAction(daemonId: String, token: Data, approve: Bool) async throws
    func open(hostId: String?, daemonId: String?, paneId: UInt64) async
    /// Marks an answered item seen on every device, so the badge and the Inbox drop it.
    func markSeen(hostId: String?, daemonId: String?, itemId: UInt64) async
}

public enum NotificationActionResult: Equatable, Sendable {
    case decided(approve: Bool)
    case opened
    case ignored
    case failed(String)
}

public struct NotificationActionHandler: Sendable {
    let client: any NotificationActionClient

    public init(client: any NotificationActionClient) {
        self.client = client
    }

    public func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], remote: Bool) async -> NotificationActionResult {
        await handle(actionIdentifier: actionIdentifier, target: NotificationTarget(userInfo: userInfo, remote: remote))
    }

    /// For callers that must read the target before crossing an actor (`userInfo` isn't `Sendable`).
    public func handle(actionIdentifier: String, target: NotificationTarget?) async -> NotificationActionResult {
        guard let target else { return .ignored }
        switch actionIdentifier {
        case PushAction.approve, PushAction.deny:
            let approve = actionIdentifier == PushAction.approve
            do {
                switch target {
                case .local(let hostId, let paneId, let itemId, let requestId, let approveOption, let denyOption):
                    guard let requestId, let optionId = approve ? approveOption : denyOption else {
                        return .failed("This request has no \(approve ? "approve" : "deny") option.")
                    }
                    try await client.decide(hostId: hostId, paneId: paneId, requestId: requestId, optionId: optionId)
                    await client.markSeen(hostId: hostId, daemonId: nil, itemId: itemId)
                case .push(let note):
                    guard let offer = note.action, let token = offer.tokenData else {
                        return .failed("This notification cannot be answered from here.")
                    }
                    guard Double(offer.expires) / 1000 > Date.now.timeIntervalSince1970 else {
                        return .failed("This request expired. Open it to answer.")
                    }
                    try await client.sendPushAction(daemonId: note.daemon, token: token, approve: approve)
                    await client.markSeen(hostId: nil, daemonId: note.daemon, itemId: note.item)
                }
                return .decided(approve: approve)
            } catch {
                return .failed(Self.describe(error))
            }
        case PushAction.open, UNNotificationDefaultActionIdentifier:
            switch target {
            case .local(let hostId, let paneId, _, _, _, _):
                await client.open(hostId: hostId, daemonId: nil, paneId: paneId)
            case .push(let note):
                await client.open(hostId: nil, daemonId: note.daemon, paneId: note.pane)
            }
            return .opened
        default:
            return .ignored
        }
    }

    static func describe(_ error: any Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.isEmpty ? "The host did not take the answer." : text
    }

    /// Posted when a lock-screen answer didn't go through, so it never fails silently.
    public static func failureContent(_ message: String, threadIdentifier: String?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Couldn’t send your answer"
        content.body = message
        content.categoryIdentifier = NotificationCategories.blocked
        if let threadIdentifier { content.threadIdentifier = threadIdentifier }
        content.interruptionLevel = .timeSensitive
        return content
    }
}
