import Foundation
import GudoCore

/// What the Share sheet is about to invite: the person, their roles, how much of the host,
/// for how long and for how many devices. Turns into the daemon's `InviteOptions`.
nonisolated public struct InviteDraft: Equatable, Sendable {
    public enum ScopeChoice: String, CaseIterable, Identifiable, Sendable {
        case host, session, tab, pane
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .host: "Host"
            case .session: "Session"
            case .tab: "Tab"
            case .pane: "Pane"
            }
        }

        /// The sentence under the picker.
        public var detail: String {
            switch self {
            case .host: "Every session on this host, plus its files and ports (drivers)."
            case .session: "This session's tabs and panes, including new ones."
            case .tab: "Only this tab."
            case .pane: "Only the focused pane."
            }
        }
    }

    public enum Expiry: String, CaseIterable, Identifiable, Sendable {
        case hour, day, week, never
        public var id: String { rawValue }

        public var ttlSecs: UInt64? {
            switch self {
            case .hour: 3_600
            case .day: 86_400
            case .week: 604_800
            case .never: nil
            }
        }

        public var title: String {
            switch self {
            case .hour: "1 hour"
            case .day: "24 hours"
            case .week: "7 days"
            case .never: "Never"
            }
        }
    }

    public enum Uses: String, CaseIterable, Identifiable, Sendable {
        case once, five, unlimited
        public var id: String { rawValue }

        public var maxUses: UInt32? {
            switch self {
            case .once: 1
            case .five: 5
            case .unlimited: nil
            }
        }

        public var title: String {
            switch self {
            case .once: "1 person"
            case .five: "5 people"
            case .unlimited: "Anyone with the link"
            }
        }
    }

    /// Who it is for, shown to everyone in the session.
    public var name = ""
    /// Roles beyond viewing (every invite can view).
    public var roles: Set<Role> = []
    public var scope = ScopeChoice.session
    public var expiry = Expiry.day
    public var uses = Uses.once
    /// The guest may invite others with narrower access.
    public var delegate = false
    /// Joining asks the owner first (knock to join): for links posted where anyone may see
    /// them.
    public var knock = false
    /// The guest sees scrollback only from when they join (the default for links).
    public var sinceJoin = true

    public init() {}

    /// The daemon's options. A scope whose id is unknown (no session yet) widens to the host
    /// only if nothing narrower exists.
    public func options(inviter: String, session: UInt64?, tab: UInt64?, pane: UInt64?) -> InviteOptions {
        let scope: Scope = switch self.scope {
        case .host: .daemon
        case .session: session.map { .session(sessionId: $0) } ?? .daemon
        case .tab: tab.map { .tab(tabId: $0) } ?? session.map { .session(sessionId: $0) } ?? .daemon
        case .pane: pane.map { .pane(paneId: $0) } ?? tab.map { .tab(tabId: $0) } ?? .daemon
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return InviteOptions(
            roles: orderedRoles, scope: scope, ttlSecs: expiry.ttlSecs, maxUses: uses.maxUses,
            delegate: delegate, label: trimmed.isEmpty ? (knock ? "" : "Guest") : trimmed, inviter: inviter,
            knock: knock, sinceJoin: sinceJoin)
    }

    /// Viewer first, then the chosen roles in a fixed order.
    public var orderedRoles: [Role] {
        [.viewer] + Role.invitable.filter { $0 != .viewer && roles.contains($0) }
    }

    /// "Driver · Tab · 24 hours · 1 person", then "asks you first".
    public var summary: String {
        var parts = [roleWords(orderedRoles), scope.title, expiry.title, uses.title]
        if knock { parts.append("asks you first") }
        return parts.joined(separator: " · ")
    }
}
