import Foundation
import HostKit
@testable import App

/// Timeline values for Chat tests, decoded from the wire's JSON as the app receives them.
nonisolated enum ChatFixtures {
    static func tool(_ kind: String, name: String? = nil, title: String? = nil, input: String = "{}",
                     status: String = "Done") -> TimelineTool {
        guard case .tool(let tool) = item("tool", body: toolBody(kind, name: name, title: title, input: input, status: status)).body
        else { preconditionFailure("a tool fixture decodes as a tool") }
        return tool
    }

    static func toolBody(_ kind: String, name: String? = nil, title: String? = nil, input: String = "{}",
                         status: String = "Done") -> [String: Any] {
        ["Tool": ["kind": kind, "name": name ?? kind, "title": title ?? name ?? kind, "input": input, "status": status,
                  "output": NSNull(), "diff": [], "exit": NSNull(), "duration_ms": 1_200, "command_mark": NSNull()]]
    }

    static func item(_ id: String, turn: String = "turn", body: [String: Any]) -> TimelineItem {
        let value: [String: Any] = ["id": id, "revision": 1, "turn": turn, "parent": NSNull(), "at": 1, "origin": "Agent", "body": body]
        let encoded = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        guard let item = try? TimelineJSON.decode(TimelineItem.self, from: String(decoding: encoded, as: UTF8.self))
        else { preconditionFailure("fixture item decodes") }
        return item
    }

    static func row(_ id: String, turn: String = "turn", body: [String: Any]) -> ChatRow {
        let item = item(id, turn: turn, body: body)
        return ChatRow(id: ChatRowID(item: id, part: 0), revision: 1, turn: turn, content: .item(item))
    }

    static func prompt(_ id: String, turn: String) -> ChatRow {
        row(id, turn: turn, body: ["User": ["text": "Do it", "attachments": [], "queued": false]])
    }

    static func reply(_ id: String, turn: String, text: String = "Done.") -> ChatRow {
        row(id, turn: turn, body: ["Assistant": ["text": text, "streaming": false]])
    }

    static func shell(_ id: String, turn: String, status: String = "Done") -> ChatRow {
        row(id, turn: turn, body: toolBody("Shell", input: #"{"command":"ls"}"#, status: status))
    }

    static func turnEnd(_ id: String, turn: String, input: UInt64? = 48_000) -> ChatRow {
        row(id, turn: turn, body: ["TurnEnd": ["duration_ms": 94_000, "input_tokens": input.map { $0 as Any } ?? NSNull(),
                                               "output_tokens": 3_100]])
    }
}
