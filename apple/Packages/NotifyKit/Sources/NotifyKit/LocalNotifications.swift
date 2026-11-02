import Foundation
import PushCrypto
import UserNotifications

/// An attention item, mapped by the app from the daemon's `AttentionItem` (NotifyKit doesn't
/// link the core).
public struct AttentionNote: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case approval(requestId: UInt64, approve: Option?, deny: Option?)
        /// An agent waits in the terminal (a question, a menu).
        case blocked
        case done
        case failed
        /// A long command finished while nobody looked.
        case command
    }

    public struct Option: Equatable, Sendable {
        public var id: UInt32
        public var label: String
        public init(id: UInt32, label: String) {
            self.id = id
            self.label = label
        }
    }

    public var hostId: String
    public var hostName: String
    public var itemId: UInt64
    public var paneId: UInt64
    public var kind: Kind
    public var title: String
    public var body: String
    public var agent: String?

    public init(hostId: String, hostName: String, itemId: UInt64, paneId: UInt64, kind: Kind, title: String, body: String, agent: String? = nil) {
        self.hostId = hostId
        self.hostName = hostName
        self.itemId = itemId
        self.paneId = paneId
        self.kind = kind
        self.title = title
        self.body = body
        self.agent = agent
    }

    /// An approval whose summary was cut (`…`) is Open only, matching the daemon's push: approve
    /// from the lock screen only what the notification shows in full.
    public var pushKind: PushKind {
        switch kind {
        case .approval(_, let approve, let deny):
            (approve == nil && deny == nil) || body.hasSuffix("…") ? .blocked : .approval
        case .blocked: .blocked
        case .done: .done
        case .failed: .failed
        case .command: .command
        }
    }
}

/// Local notifications from the attention feed while the app is alive in the background;
/// pushes cover the rest.
public enum LocalNotifications {
    public static let localKey = "local"

    /// One per pane, so a newer note for the same pane replaces the older one in Notification
    /// Center, matching the daemon's push collapse id.
    public static func identifier(hostId: String, paneId: UInt64) -> String {
        "pane.\(hostId).\(paneId)"
    }

    public static func content(for note: AttentionNote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = note.title.isEmpty ? defaultTitle(note) : note.title
        content.subtitle = [note.agent, note.hostName].compactMap { $0 }.joined(separator: " · ")
        content.body = note.body
        content.categoryIdentifier = note.pushKind.categoryIdentifier
        content.threadIdentifier = note.hostId
        content.sound = note.pushKind == .approval || note.pushKind == .blocked ? .default : nil
        content.interruptionLevel = switch note.pushKind {
        case .approval, .blocked: .timeSensitive
        case .done, .failed, .command: .active
        }
        content.relevanceScore = note.pushKind == .approval ? 1 : 0.5
        var local: [String: Any] = [
            "host": note.hostId,
            "pane": NSNumber(value: note.paneId),
            "item": NSNumber(value: note.itemId),
        ]
        if case .approval(let request, let approve, let deny) = note.kind, note.pushKind == .approval {
            local["request"] = NSNumber(value: request)
            if let approve { local["approve"] = NSNumber(value: approve.id) }
            if let deny { local["deny"] = NSNumber(value: deny.id) }
        }
        content.userInfo = [localKey: local]
        return content
    }

    static func defaultTitle(_ note: AttentionNote) -> String {
        switch note.pushKind {
        case .approval: "Approval needed"
        case .blocked: "An agent is waiting for you"
        case .done: "Agent finished"
        case .failed: "Agent failed"
        case .command: "Command finished"
        }
    }

    /// A visible terminal alerts by itself, so by default only post while the app isn't active.
    public static func shouldPost(_ note: AttentionNote, prefs: NotificationPrefs, appIsActive: Bool) -> Bool {
        guard prefs.allows(note.pushKind) else { return false }
        return !(prefs.onlyInBackground && appIsActive)
    }
}

public enum NotificationTarget: Equatable, Sendable {
    /// Answered over the host's live connection.
    case local(hostId: String, paneId: UInt64, itemId: UInt64, requestId: UInt64?, approve: UInt32?, deny: UInt32?)
    /// Answered on a one-shot, device-signed connection.
    case push(PushNotification)

    /// `remote`: the notification came through APNs. Its `userInfo` is then only trusted as a
    /// payload the extension opened and verified; a local target in it would let whoever can
    /// push to this device pick the request an Approve answers.
    public init?(userInfo: [AnyHashable: Any], remote: Bool) {
        if remote {
            guard let push = PushContent.payload(from: userInfo) else { return nil }
            self = .push(push)
        } else if let local = userInfo[LocalNotifications.localKey] as? [String: Any],
           let hostId = local["host"] as? String,
           let paneId = (local["pane"] as? NSNumber)?.uint64Value
        {
            self = .local(
                hostId: hostId, paneId: paneId,
                itemId: (local["item"] as? NSNumber)?.uint64Value ?? 0,
                requestId: (local["request"] as? NSNumber)?.uint64Value,
                approve: (local["approve"] as? NSNumber)?.uint32Value,
                deny: (local["deny"] as? NSNumber)?.uint32Value)
        } else {
            return nil
        }
    }
}
