import Foundation
import HostKit

/// A tool call on one line, as people read it: a verb and what it acted on, "Shell
/// git status --short", "Read src/app.ts", "Search TODO", with a glyph for its kind.
nonisolated struct ChatToolLine: Equatable, Sendable {
    let verb: String
    let detail: String
    let symbol: String

    private static let detailLimit = 512
    private static let inputLimit = 16_384

    init(_ tool: TimelineTool, workingDirectory: String? = nil) {
        let input = Self.input(tool)
        symbol = Self.symbol(tool.kind)
        switch tool.kind {
        case .known(.shell):
            verb = "Shell"
            detail = Self.command(input?["command"]) ?? Self.fallback(tool)
        case .known(.read):
            verb = "Read"
            detail = Self.path(input, in: workingDirectory) ?? Self.fallback(tool)
        case .known(.edit):
            verb = "Edit"
            detail = Self.path(input, in: workingDirectory) ?? Self.fallback(tool)
        case .known(.write):
            verb = "Write"
            detail = Self.path(input, in: workingDirectory) ?? Self.fallback(tool)
        case .known(.search):
            verb = "Search"
            detail = Self.text(input, keys: ["pattern", "query", "glob"]) ?? Self.fallback(tool)
        case .known(.fetch):
            verb = "Fetch"
            detail = Self.text(input, keys: ["url"]) ?? Self.fallback(tool)
        case .known(.webSearch):
            verb = "Web search"
            detail = Self.text(input, keys: ["query"]) ?? Self.fallback(tool)
        case .known(.task):
            verb = Self.text(input, keys: ["subagent_type"]).map(Self.humanized) ?? "Task"
            detail = Self.text(input, keys: ["description", "prompt"]) ?? Self.fallback(tool)
        case .known(.mcp):
            let parts = tool.name.components(separatedBy: "__").filter { !$0.isEmpty }
            if parts.count >= 3, parts[0] == "mcp" {
                verb = Self.humanized(parts[1])
                detail = Self.humanized(parts.dropFirst(2).joined(separator: " "))
            } else {
                verb = Self.humanized(tool.name)
                detail = Self.fallback(tool)
            }
        case .known(.other), .unknown:
            verb = Self.humanized(tool.name)
            detail = Self.fallback(tool)
        }
    }

    /// The whole line for accessibility and copying.
    var text: String { detail.isEmpty ? verb : verb + " " + detail }

    static func symbol(_ kind: TimelineToolKind) -> String {
        switch kind {
        case .known(.shell): "terminal"
        case .known(.read): "eye"
        case .known(.search): "magnifyingglass"
        case .known(.edit), .known(.write): "pencil"
        case .known(.fetch), .known(.webSearch): "globe"
        case .known(.mcp): "puzzlepiece.extension"
        case .known(.task): "person.2"
        case .known(.other), .unknown: "wrench.and.screwdriver"
        }
    }

    private static func input(_ tool: TimelineTool) -> [String: Any]? {
        guard !tool.input.isEmpty, tool.input.utf8.count <= inputLimit else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(tool.input.utf8))) as? [String: Any]
    }

    /// A shell command on one line; Codex records `["bash", "-lc", "…"]`.
    private static func command(_ value: Any?) -> String? {
        if let command = value as? String { return line(command) }
        guard let parts = value as? [String], !parts.isEmpty else { return nil }
        if parts.count == 3, ["bash", "zsh", "sh"].contains((parts[0] as NSString).lastPathComponent),
           ["-lc", "-c"].contains(parts[1]) {
            return line(parts[2])
        }
        return line(parts.joined(separator: " "))
    }

    private static func path(_ input: [String: Any]?, in workingDirectory: String?) -> String? {
        guard let path = text(input, keys: ["file_path", "path", "notebook_path"]) else { return nil }
        guard let directory = workingDirectory, !directory.isEmpty else { return path }
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count ? String(path.dropFirst(prefix.count)) : path
    }

    private static func text(_ input: [String: Any]?, keys: [String]) -> String? {
        for key in keys {
            if let value = input?[key] as? String, let text = line(value) { return text }
        }
        return nil
    }

    private static func fallback(_ tool: TimelineTool) -> String {
        tool.title == tool.name ? "" : line(tool.title) ?? ""
    }

    /// One line: whitespace runs, newlines included, read as one space.
    private static func line(_ text: String) -> String? {
        let words = text.prefix(detailLimit * 4).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        return joined.count > detailLimit ? String(joined.prefix(detailLimit)) + "…" : joined
    }

    /// `web_fetch`, `pane-send` and `codeReview` read as "Web fetch", "Pane send", "Code review".
    static func humanized(_ name: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in name {
            if character == "_" || character == "-" || character == "." { spaced.append(" ") }
            else if character.isUppercase, let previous, previous.isLowercase { spaced.append(" "); spaced.append(character) }
            else { spaced.append(character) }
            previous = character
        }
        let words = spaced.split(separator: " ")
        guard let first = words.first else { return name }
        let text = ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst().map { $0.lowercased() })
            .joined(separator: " ")
        return text
    }
}
