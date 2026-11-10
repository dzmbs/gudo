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
    /// The agent's display name ("Claude Code").
    public var agent: String?
    /// The daemon's name for the agent (`claude`), which per-agent preferences use.
    public var agentId: String?
    /// The pane's project, tab or directory.
    public var place: String?

    public init(
        hostId: String, hostName: String, itemId: UInt64, paneId: UInt64, kind: Kind, title: String, body: String,
        agent: String? = nil, agentId: String? = nil, place: String? = nil
    ) {
        self.hostId = hostId
        self.hostName = hostName
        self.itemId = itemId
        self.paneId = paneId
        self.kind = kind
        self.title = title
        self.body = body
        self.agent = agent
        self.agentId = agentId
        self.place = place
    }

    /// Finished (or failed) turns, which wait out a turn that goes straight on and are paced
    /// per pane.
    public var isFinished: Bool {
        switch kind {
        case .done, .failed: true
        default: false
        }
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

    /// Notification Center groups each pane's notes together.
    public static func thread(hostId: String, paneId: UInt64) -> String {
        "\(hostId).pane.\(paneId)"
    }

    public static func content(for note: AttentionNote) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = note.title.isEmpty ? defaultTitle(note) : note.title
        content.subtitle = [note.place, note.hostName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        content.body = body(note)
        content.categoryIdentifier = note.pushKind.categoryIdentifier
        content.threadIdentifier = thread(hostId: note.hostId, paneId: note.paneId)
        content.sound = .default
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
        let agent = note.agent ?? "Agent"
        return switch note.pushKind {
        case .approval, .blocked: "\(agent) needs you"
        case .done: "\(agent) finished"
        case .failed: "\(agent) failed"
        case .command: "Command finished"
        }
    }

    /// A finished turn says the first line of its last message; the rest is in the app.
    static func body(_ note: AttentionNote) -> String {
        switch note.kind {
        case .done: summaryLine(note.body) ?? "Finished"
        case .failed: summaryLine(note.body) ?? "The turn ended with an error."
        default: note.body
        }
    }

    static let summaryLimit = 140

    /// The first line with words in it, without Markdown heading, list, quote and emphasis
    /// marks, cut to ``summaryLimit`` characters.
    public static func summaryLine(_ message: String) -> String? {
        let line = message.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces).drop { "#>-*+".contains($0) }.trimmingCharacters(in: .whitespaces) }
            .first { $0.contains { $0.isLetter || $0.isNumber } }
        guard let line else { return nil }
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .filter { !$0.unicodeScalars.contains { $0.properties.generalCategory == .format || $0.properties.generalCategory == .control } }
        guard plain.count > summaryLimit else { return plain }
        return String(plain.prefix(summaryLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whether to post `note` now. Never for a kind or agent switched off, nor for a pane on
    /// screen in front (the user is looking at it), nor in front at all with "only in the
    /// background". In the background, a host that pushes to this device covers it, so the
    /// note would only be a second copy.
    public static func shouldPost(
        _ note: AttentionNote, prefs: NotificationPrefs, appIsActive: Bool,
        paneOnScreen: Bool = false, pushCoversBackground: Bool = false
    ) -> Bool {
        guard prefs.allows(note.pushKind, agent: note.agentId) else { return false }
        if appIsActive { return !prefs.onlyInBackground && !paneOnScreen }
        return !pushCoversBackground
    }

    /// How a note shows while the app is in front: not at all for the pane on screen, else as
    /// a banner.
    public static func presentation(paneOnScreen: Bool) -> UNNotificationPresentationOptions {
        paneOnScreen ? [] : [.banner, .list, .sound]
    }
}

/// Paces finished-turn notes per pane: at most one per ``interval``; one that comes sooner waits
/// for the rest of it (and is replaced by a newer one meanwhile).
public struct PaneNotePacer: Sendable {
    public var interval: Duration
    private(set) var lastPosted: [String: ContinuousClock.Instant] = [:]

    public init(interval: Duration = .seconds(30)) {
        self.interval = interval
    }

    /// How long a note for `key` must wait at `now`.
    public func wait(for key: String, now: ContinuousClock.Instant) -> Duration {
        guard let last = lastPosted[key] else { return .zero }
        let elapsed = now - last
        return elapsed >= interval ? .zero : interval - elapsed
    }

    public mutating func posted(_ key: String, at now: ContinuousClock.Instant) {
        lastPosted = lastPosted.filter { now - $0.value < interval }
        lastPosted[key] = now
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
