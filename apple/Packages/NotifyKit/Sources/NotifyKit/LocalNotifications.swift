import Foundation
import PushCrypto
import UserNotifications

/// One attention item as the notifier sees it (the app maps the daemon's `AttentionItem` and
/// the pane's agent options into this; NotifyKit does not link the core).
public struct AttentionNote: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// An agent asks to run something. Options let Approve / Deny answer it in place.
        case approval(requestId: UInt64, approve: Option?, deny: Option?)
        /// An agent waits in the terminal (a question, a menu).
        case blocked
        case done
        case failed
        /// A long command finished while nobody looked.
        case command
    }

    /// An option of the agent's request (`AgentOption`).
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
    /// The agent ("Claude Code"), for the subtitle.
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

    /// The push kind it corresponds to (category, preferences).
    public var pushKind: PushKind {
        switch kind {
        case .approval(_, let approve, let deny): approve == nil && deny == nil ? .blocked : .approval
        case .blocked: .blocked
        case .done: .done
        case .failed: .failed
        case .command: .command
        }
    }
}

/// Builds local notifications from the attention feed (the app is alive in the background;
/// pushes cover the rest). The `userInfo` carries what the action handler needs.
public enum LocalNotifications {
    /// `userInfo` key of the local payload (a `[String: Any]` plist dictionary).
    public static let localKey = "local"

    /// The request identifier: one per pane, so a newer note for the same pane replaces the
    /// older one in Notification Center (as the daemon's push collapse id does).
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
        if case .approval(let request, let approve, let deny) = note.kind {
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

    /// Whether to post now: the preferences allow the kind, and (by default) the app is not
    /// active (a visible terminal alerts by itself).
    public static func shouldPost(_ note: AttentionNote, prefs: NotificationPrefs, appIsActive: Bool) -> Bool {
        guard prefs.allows(note.pushKind) else { return false }
        return !(prefs.onlyInBackground && appIsActive)
    }
}

/// What an action on a notification refers to, read back from `userInfo`.
public enum NotificationTarget: Equatable, Sendable {
    /// A local notification: the host's live connection answers.
    case local(hostId: String, paneId: UInt64, itemId: UInt64, requestId: UInt64?, approve: UInt32?, deny: UInt32?)
    /// A push opened by the NSE: a one-shot, device-signed connection answers.
    case push(PushNotification)

    public init?(userInfo: [AnyHashable: Any]) {
        if let local = userInfo[LocalNotifications.localKey] as? [String: Any],
           let host = local["host"] as? String,
           let pane = (local["pane"] as? NSNumber)?.uint64Value
        {
            self = .local(
                hostId: host, paneId: pane,
                itemId: (local["item"] as? NSNumber)?.uint64Value ?? 0,
                requestId: (local["request"] as? NSNumber)?.uint64Value,
                approve: (local["approve"] as? NSNumber)?.uint32Value,
                deny: (local["deny"] as? NSNumber)?.uint32Value)
        } else if let push = PushContent.payload(from: userInfo) {
            self = .push(push)
        } else {
            return nil
        }
    }
}
