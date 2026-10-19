import Foundation

/// One agent run on the Lock Screen and in the Dynamic Island: which agent, on which host and
/// pane, doing what. Updated locally by the app while it is alive (the daemon does not send
/// Live Activity pushes yet; docs/PUSH.md §6 keeps a sealed `ContentState` for that).
public struct AgentRunState: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case working, blocked, done, failed

        public var title: String {
            switch self {
            case .working: "Working"
            case .blocked: "Needs you"
            case .done: "Done"
            case .failed: "Failed"
            }
        }

        /// SF Symbol for the phase (shape carries meaning, not only color).
        public var systemImage: String {
            switch self {
            case .working: "circle.dotted"
            case .blocked: "exclamationmark.circle.fill"
            case .done: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            }
        }

        public var isFinal: Bool { self == .done || self == .failed }
    }

    public var phase: Phase
    /// The one line that matters: the tool and command it waits on, the last message.
    public var headline: String
    /// When the run started (the timer counts from here while working).
    public var startedAt: Date
    public var updatedAt: Date

    public init(phase: Phase, headline: String, startedAt: Date, updatedAt: Date = .now) {
        self.phase = phase
        self.headline = headline
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// ActivityKit attributes of an agent run (static for the activity's life).
public struct AgentRunAttributes: ActivityAttributes {
    public typealias ContentState = AgentRunState

    /// "Claude Code", "Codex".
    public var agent: String
    public var hostName: String
    public var hostId: String
    public var paneId: UInt64
    /// The task as the user gave it, shortened.
    public var task: String

    public init(agent: String, hostName: String, hostId: String, paneId: UInt64, task: String) {
        self.agent = agent
        self.hostName = hostName
        self.hostId = hostId
        self.paneId = paneId
        self.task = task
    }

    /// `unnamed://open/<host>/<pane>`-style deep link the activity opens.
    public func openURL(scheme: String) -> URL? {
        URL(string: "\(scheme)://open/\(hostId)/\(paneId)")
    }
}
#endif
