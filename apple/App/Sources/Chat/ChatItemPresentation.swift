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

    /// Only a call that did not finish names its state on its row; running shimmers, done shows its time.
    static func toolStateLabel(_ tool: TimelineTool) -> String? {
        switch tool.status {
        case .known(.running), .known(.done): nil
        default: toolStatus(tool)
        }
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
