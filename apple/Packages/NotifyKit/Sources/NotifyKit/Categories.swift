import Foundation
import PushCrypto
import UserNotifications

/// Pushes and local notifications use the same identifiers, so one action handler serves both.
public enum NotificationCategories {
    public static let approval = PushKind.approval.categoryIdentifier
    public static let blocked = PushKind.blocked.categoryIdentifier
    public static let agentDone = PushKind.done.categoryIdentifier
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

/// One agent's notifications, on top of the kinds: "needs you" covers approvals and questions,
/// "finished" a turn that ended (or failed).
public struct AgentNotificationPrefs: Codable, Equatable, Sendable {
    public var needsYou = true
    public var finished = true

    public init(needsYou: Bool = true, finished: Bool = true) {
        self.needsYou = needsYou
        self.finished = finished
    }
}

/// The same choices go to every daemon as `PushPrefs` (and per agent as `PushAgents`) when push
/// is registered, and gate local notifications.
public struct NotificationPrefs: Codable, Equatable, Sendable {
    public var approvals = true
    public var blocked = true
    public var done = true
    public var failed = true
    public var commands = true
    /// Off: in front, notes still come for panes that are not on screen; the pane being looked
    /// at never notifies.
    public var onlyInBackground = false
    /// Keyed by the daemon's agent name (`claude`, `codex`), and ``otherAgents`` for the rest.
    public var agents: [String: AgentNotificationPrefs] = [:]

    public static let otherAgents = "*"

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approvals = try container.decodeIfPresent(Bool.self, forKey: .approvals) ?? true
        blocked = try container.decodeIfPresent(Bool.self, forKey: .blocked) ?? true
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? true
        failed = try container.decodeIfPresent(Bool.self, forKey: .failed) ?? true
        commands = try container.decodeIfPresent(Bool.self, forKey: .commands) ?? true
        onlyInBackground = try container.decodeIfPresent(Bool.self, forKey: .onlyInBackground) ?? false
        agents = try container.decodeIfPresent([String: AgentNotificationPrefs].self, forKey: .agents) ?? [:]
    }

    public func allows(_ kind: PushKind) -> Bool {
        switch kind {
        case .approval: approvals
        case .blocked: blocked
        case .done: done
        case .failed: failed
        case .command: commands
        }
    }

    /// The kind's switch, then the agent's own choice (or the other agents').
    public func allows(_ kind: PushKind, agent: String?) -> Bool {
        guard allows(kind) else { return false }
        guard let agent else { return true }
        let choice = self.agent(agent)
        return switch kind {
        case .approval, .blocked: choice.needsYou
        case .done, .failed: choice.finished
        case .command: true
        }
    }

    public func agent(_ name: String) -> AgentNotificationPrefs {
        agents[name] ?? agents[Self.otherAgents] ?? AgentNotificationPrefs()
    }

    static let key = "notification-prefs"

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
