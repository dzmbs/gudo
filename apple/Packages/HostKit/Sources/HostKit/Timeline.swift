import Foundation
import GudoCore

nonisolated public protocol DaemonTimelineAPI: AnyObject, Sendable {
    func timelineWatch(paneId: UInt64) async throws -> String
    func timelineUnwatch(paneId: UInt64) async throws
    func timelineItemsBefore(paneId: UInt64, before: UInt64, limit: UInt16) async throws -> String
    func timelineToolOutput(paneId: UInt64, handle: String, offset: UInt64, len: UInt32) async throws -> String
}

extension DaemonClient: DaemonTimelineAPI {}

nonisolated public struct TimelineCursor: Codable, Equatable, Sendable {
    public var epoch: UInt64
    public var sequence: UInt64
}

nonisolated public struct TimelineSession: Codable, Equatable, Sendable {
    public var agent: String
    public var nativeSession: String
    public var title: String?
    public var model: String?
    public var permissionMode: String?
    public var commands: [TimelineCommand]
    private enum CodingKeys: String, CodingKey {
        case agent, title, model, commands
        case nativeSession = "native_session", permissionMode = "permission_mode"
    }
}

nonisolated public struct TimelineCommand: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var source: String
    public var id: String { name }
}

nonisolated public struct TimelineSnapshot: Codable, Equatable, Sendable {
    public var cursor: TimelineCursor
    public var session: TimelineSession
    public var items: [TimelineItem]
    public var before: UInt64?
}

nonisolated public struct TimelineItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var revision: UInt32
    public var turn: String?
    public var parent: String?
    public var at: UInt64
    public var origin: TimelineOrigin
    public var body: TimelineBody
}

nonisolated public enum TimelineOrigin: Codable, Equatable, Sendable {
    case terminal, agent, app(TimelineActor)

    private enum Keys: String, CodingKey { case app = "App" }

    public init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            switch text {
            case "Terminal": self = .terminal
            case "Agent": self = .agent
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported timeline origin"))
            }
        } else {
            self = .app(try decoder.container(keyedBy: Keys.self).decode(TimelineActor.self, forKey: .app))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .terminal: var container = encoder.singleValueContainer(); try container.encode("Terminal")
        case .agent: var container = encoder.singleValueContainer(); try container.encode("Agent")
        case .app(let actor): var container = encoder.container(keyedBy: Keys.self); try container.encode(actor, forKey: .app)
        }
    }
}

nonisolated public struct TimelineActor: Codable, Equatable, Sendable {
    public var principal: [UInt8]
    public var device: [UInt8]
}

nonisolated public struct TimelineUser: Codable, Equatable, Sendable {
    public var text: String
    public var attachments: [TimelineAttachment]
    public var queued: Bool
}

nonisolated public struct TimelineAttachment: Codable, Equatable, Sendable {
    public var path: String
    public var mediaType: String?
    private enum CodingKeys: String, CodingKey { case path; case mediaType = "media_type" }
}

nonisolated public struct TimelineAssistant: Codable, Equatable, Sendable {
    public var text: String
    public var streaming: Bool
}

nonisolated public struct TimelineThinking: Codable, Equatable, Sendable {
    public var text: String?
    public var durationMs: UInt64?
    private enum CodingKeys: String, CodingKey { case text; case durationMs = "duration_ms" }
}

nonisolated public struct TimelinePlan: Codable, Equatable, Sendable {
    public var entries: [TimelinePlanEntry]
}

nonisolated public struct TimelinePlanEntry: Codable, Equatable, Sendable {
    public var text: String
    public var status: String
}

nonisolated public struct TimelineNotice: Codable, Equatable, Sendable {
    public var kind: String
    public var text: String
}

nonisolated public struct TimelineTurnEnd: Codable, Equatable, Sendable {
    public var durationMs: UInt64
    public var inputTokens: UInt64?
    public var outputTokens: UInt64?
    private enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms", inputTokens = "input_tokens", outputTokens = "output_tokens"
    }
}

nonisolated public struct TimelineTool: Codable, Equatable, Sendable {
    public var kind: String
    public var name: String
    public var title: String
    public var input: String
    public var status: String
    public var output: TimelineOutputReference?
    public var diff: [TimelineFileDiff]
    public var exit: Int32?
    public var durationMs: UInt64?
    public var commandMark: UInt64?
    private enum CodingKeys: String, CodingKey {
        case kind, name, title, input, status, output, diff, exit
        case durationMs = "duration_ms", commandMark = "command_mark"
    }
}

nonisolated public struct TimelineOutputReference: Codable, Equatable, Sendable {
    public var handle: String
    public var preview: String
    public var bytes: UInt64
}

nonisolated public struct TimelineFileDiff: Codable, Equatable, Sendable {
    public var path: String
    public var oldPath: String?
    public var change: String
    public var binary: Bool
    public var additions: UInt32
    public var deletions: UInt32
    public var hunks: [TimelineHunk]
    public var hunksOmitted: Bool
    private enum CodingKeys: String, CodingKey {
        case path, change, binary, additions, deletions, hunks
        case oldPath = "old_path", hunksOmitted = "hunks_omitted"
    }
}

nonisolated public struct TimelineHunk: Codable, Equatable, Sendable {
    public var oldStart: UInt32
    public var oldLines: UInt32
    public var newStart: UInt32
    public var newLines: UInt32
    public var header: String
    public var lines: [TimelineDiffLine]
    private enum CodingKeys: String, CodingKey {
        case header, lines
        case oldStart = "old_start", oldLines = "old_lines", newStart = "new_start", newLines = "new_lines"
    }
}

nonisolated public struct TimelineDiffLine: Codable, Equatable, Sendable {
    public var kind: String
    public var text: String
}

nonisolated public enum TimelineBody: Codable, Equatable, Sendable {
    case user(TimelineUser)
    case assistant(TimelineAssistant)
    case thinking(TimelineThinking)
    case tool(TimelineTool)
    case plan(TimelinePlan)
    case notice(TimelineNotice)
    case turnEnd(TimelineTurnEnd)

    private enum Keys: String, CodingKey {
        case user = "User", assistant = "Assistant", thinking = "Thinking", tool = "Tool"
        case plan = "Plan", notice = "Notice", turnEnd = "TurnEnd"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported timeline item"))
        }
        switch key {
        case .user: self = .user(try container.decode(TimelineUser.self, forKey: key))
        case .assistant: self = .assistant(try container.decode(TimelineAssistant.self, forKey: key))
        case .thinking: self = .thinking(try container.decode(TimelineThinking.self, forKey: key))
        case .tool: self = .tool(try container.decode(TimelineTool.self, forKey: key))
        case .plan: self = .plan(try container.decode(TimelinePlan.self, forKey: key))
        case .notice: self = .notice(try container.decode(TimelineNotice.self, forKey: key))
        case .turnEnd: self = .turnEnd(try container.decode(TimelineTurnEnd.self, forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .user(let value): try container.encode(value, forKey: .user)
        case .assistant(let value): try container.encode(value, forKey: .assistant)
        case .thinking(let value): try container.encode(value, forKey: .thinking)
        case .tool(let value): try container.encode(value, forKey: .tool)
        case .plan(let value): try container.encode(value, forKey: .plan)
        case .notice(let value): try container.encode(value, forKey: .notice)
        case .turnEnd(let value): try container.encode(value, forKey: .turnEnd)
        }
    }
}

nonisolated public struct TimelineUpdate: Decodable, Sendable {
    public var paneId: UInt64
    public var operations: [TimelineOperation]
    private enum CodingKeys: String, CodingKey { case operations; case paneId = "pane_id" }
}

nonisolated public enum TimelineOperation: Decodable, Sendable {
    case snapshot(TimelineSnapshot)
    case upsert(TimelineCursor, TimelineItem)
    case append(TimelineCursor, id: String, field: String, text: String)
    case remove(TimelineCursor, id: String)
    case session(TimelineCursor, TimelineSession)
    case unavailable(String)
    case checkpoint(TimelineCursor)

    private enum Keys: String, CodingKey {
        case snapshot = "Snapshot", upsert = "Upsert", append = "Append", remove = "Remove"
        case session = "Session", unavailable = "Unavailable", checkpoint = "Checkpoint"
    }
    private enum Fields: String, CodingKey { case cursor, item, id, field, text, session, message }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        guard let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unsupported timeline operation"))
        }
        if key == .snapshot {
            self = .snapshot(try container.decode(TimelineSnapshot.self, forKey: key))
            return
        }
        let fields = try container.nestedContainer(keyedBy: Fields.self, forKey: key)
        if key == .unavailable {
            self = .unavailable(try fields.decode(String.self, forKey: .message))
            return
        }
        let cursor = try fields.decode(TimelineCursor.self, forKey: .cursor)
        switch key {
        case .upsert: self = .upsert(cursor, try fields.decode(TimelineItem.self, forKey: .item))
        case .append: self = .append(cursor, id: try fields.decode(String.self, forKey: .id), field: try fields.decode(String.self, forKey: .field), text: try fields.decode(String.self, forKey: .text))
        case .remove: self = .remove(cursor, id: try fields.decode(String.self, forKey: .id))
        case .session: self = .session(cursor, try fields.decode(TimelineSession.self, forKey: .session))
        case .checkpoint: self = .checkpoint(cursor)
        case .snapshot, .unavailable:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid timeline operation"))
        }
    }
}

nonisolated public struct TimelineToolOutput: Decodable, Sendable {
    public var text: String
    public var nextOffset: UInt64?
    public var totalBytes: UInt64
    private enum CodingKeys: String, CodingKey { case text; case nextOffset = "next_offset", totalBytes = "total_bytes" }
}

nonisolated public enum TimelineJSON {
    public static func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: Data(json.utf8))
    }

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(value)
    }
}

extension DaemonWorkspace {
    public func observeTimeline(pane: UInt64, _ handler: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        timelineObservers[token] = (pane, handler)
        return token
    }

    public func timelineClient() throws -> any DaemonTimelineAPI {
        guard let client = try client() as? any DaemonTimelineAPI else { throw HostError.notConnected }
        return client
    }
}
