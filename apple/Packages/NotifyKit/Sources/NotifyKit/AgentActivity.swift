import Foundation

/// One agent run on the Lock Screen and in the Dynamic Island, updated locally by the app while
/// it is alive.
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

        /// Shape carries the meaning, not only colour.
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
    /// The tool and command it waits on, or the last message.
    public var headline: String
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

    /// `<scheme>://open/<host>/<pane>`.
    public func openURL(scheme: String) -> URL? {
        URL(string: "\(scheme)://open/\(hostId)/\(paneId)")
    }
}
#endif
