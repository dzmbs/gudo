import Foundation
import PushCrypto
import UserNotifications

/// What the action handler needs from the app: the live connection for local notifications,
/// a one-shot signed connection for pushes, and a way to show the pane.
public protocol NotificationActionClient: Sendable {
    /// Answers an agent request over the host's live connection (signed `decide`).
    func decide(hostId: String, paneId: UInt64, requestId: UInt64, optionId: UInt32) async throws
    /// Answers a push's request on a one-shot connection signed with the device key
    /// (`sendPushAction`); `daemonId` picks the saved ticket.
    func sendPushAction(daemonId: String, token: Data, approve: Bool) async throws
    /// Brings the pane forward (the app is foregrounded by the `.foreground` action).
    func open(hostId: String?, daemonId: String?, paneId: UInt64) async
    /// Marks an answered item seen on every device, so the badge and the Inbox drop it.
    func markSeen(hostId: String?, daemonId: String?, itemId: UInt64) async
}

/// The outcome of one tap, for logs, tests and a follow-up notification on failure.
public enum NotificationActionResult: Equatable, Sendable {
    case decided(approve: Bool)
    case opened
    /// Dismissed, or nothing to do.
    case ignored
    /// The decision could not be sent (expired, already answered, unreachable).
    case failed(String)
}

/// Routes notification actions (APPROVE / DENY / OPEN / default tap) to the client.
public struct NotificationActionHandler: Sendable {
    let client: any NotificationActionClient

    public init(client: any NotificationActionClient) {
        self.client = client
    }

    public func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], remote: Bool) async -> NotificationActionResult {
        await handle(actionIdentifier: actionIdentifier, target: NotificationTarget(userInfo: userInfo, remote: remote))
    }

    /// The same, with the target already read from `userInfo` (which is not `Sendable`).
    public func handle(actionIdentifier: String, target: NotificationTarget?) async -> NotificationActionResult {
        guard let target else { return .ignored }
        switch actionIdentifier {
        case PushAction.approve, PushAction.deny:
            let approve = actionIdentifier == PushAction.approve
            do {
                switch target {
                case .local(let host, let pane, let item, let request, let approveOption, let denyOption):
                    guard let request, let option = approve ? approveOption : denyOption else {
                        return .failed("This request has no \(approve ? "approve" : "deny") option.")
                    }
                    try await client.decide(hostId: host, paneId: pane, requestId: request, optionId: option)
                    await client.markSeen(hostId: host, daemonId: nil, itemId: item)
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
            case .local(let host, let pane, _, _, _, _):
                await client.open(hostId: host, daemonId: nil, paneId: pane)
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

    /// A follow-up when a lock-screen answer did not go through, so it never fails silently.
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
