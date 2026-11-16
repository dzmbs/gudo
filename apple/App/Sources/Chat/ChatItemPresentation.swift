#if os(iOS)
import Foundation
import HostKit

nonisolated enum ChatItemPresentation {
    static func duration(_ milliseconds: UInt64) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        let seconds = milliseconds / 1_000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }

    static func thinkingTitle(_ thinking: TimelineThinking) -> String {
        if let time = thinking.durationMs { return "Thought for " + duration(time) }
        return "Thinking"
    }

    /// "14:32" today, "12 Nov, 14:32" before; nothing for a prompt with no recorded time.
    static func promptTime(_ milliseconds: UInt64, now: Date = .now, calendar: Calendar = .current,
                           locale: Locale = .current) -> String? {
        guard milliseconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        var style = Date.FormatStyle(date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }

    static func hasThinkingText(_ thinking: TimelineThinking) -> Bool { thinking.text?.isEmpty == false }

    static func toolTitle(_ tool: TimelineTool) -> String {
        let title = tool.title.isEmpty ? tool.name : tool.title
        let prefix = String(String.UnicodeScalarView(title.unicodeScalars.prefix(512)))
        return prefix + (title.unicodeScalars.dropFirst(512).isEmpty ? "" : "…")
    }

    static func toolStatus(_ tool: TimelineTool) -> String {
        switch tool.status {
        case .known(.running): "Running"
        case .known(.done): "Completed"
        case .known(.failed): "Failed"
        case .known(.denied): "Denied"
        case .known(.interrupted): "Interrupted"
        case .unknown: "Status unavailable"
        }
    }

    /// Only a call that did not finish names its state on its row; running shimmers, done shows its
    /// time. A failed command adds its exit code, "Failed · exit 101".
    static func toolStateLabel(_ tool: TimelineTool) -> String? {
        switch tool.status {
        case .known(.running), .known(.done): nil
        case .known(.failed): tool.exit.map { "Failed · exit \($0)" } ?? toolStatus(tool)
        default: toolStatus(tool)
        }
    }

    /// What a call was given, as people read it: "$ cargo test" for a command, the path for a file.
    /// Anything else shows its recorded input as it is.
    static func toolInputSummary(_ tool: TimelineTool) -> String? {
        guard !tool.input.isEmpty else { return nil }
        let raw = String(tool.input.prefix(2_000))
        let object = tool.input.utf8.count <= 16_384
            ? (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8))) as? [String: Any] : nil
        switch tool.kind {
        case .known(.shell):
            if let command = object?["command"] as? String { return "$ " + String(command.prefix(2_000)) }
            return object == nil ? "$ " + raw : raw
        case .known(.read), .known(.edit), .known(.write):
            return (object?["file_path"] ?? object?["path"]) as? String ?? raw
        default:
            return raw
        }
    }

    /// "Worked for 1m 34s · 3.1K tokens".
    static func turnSummary(_ end: TimelineTurnEnd) -> String {
        var parts = ["Worked for " + duration(end.durationMs)]
        if let tokens = end.outputTokens { parts.append(tokens.formatted(.number.notation(.compactName)) + " tokens") }
        return parts.joined(separator: " · ")
    }

    static func toolKind(_ tool: TimelineTool) -> String {
        switch tool.kind {
        case .known(.shell): "Command"
        case .known(.read): "Read"
        case .known(.search): "Search"
        case .known(.edit): "Edit"
        case .known(.write): "Write"
        case .known(.fetch): "Fetch"
        case .known(.webSearch): "Web search"
        case .known(.mcp): "MCP tool"
        case .known(.task): "Subagent"
        case .known(.other), .unknown: "Tool"
        }
    }

}
#endif
