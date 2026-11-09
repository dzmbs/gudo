import Foundation

/// What a tab running an agent is called, so three Claude Codes in one project read apart:
/// the user's rename, else the agent's own session title, else the first prompt, else the
/// terminal title the agent set (cleaned), else the agent's kind. The kind is the icon's job.
nonisolated struct AgentTabTitle: Equatable, Sendable {
    var rename: String?
    var sessionTitle: String?
    var firstPrompt: String?
    var terminalTitle: String?
    var kind: AgentKind

    var resolved: String {
        if let chosen = [rename, sessionTitle, firstPrompt].lazy.compactMap({ $0.flatMap(Self.meaningful) }).first {
            return chosen
        }
        if let terminal = terminalTitle.flatMap(Self.cleanedTerminalTitle), !names(kind: terminal) {
            return terminal
        }
        return kind.title
    }

    private func names(kind title: String) -> Bool {
        let lowered = title.lowercased()
        return lowered == kind.title.lowercased() || lowered == kind.rawValue
            || AgentKind.allCases.contains { $0.title.lowercased() == lowered || $0.rawValue == lowered }
    }

    private static func meaningful(_ text: String) -> String? {
        let trimmed = oneLine(text)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The title without the status marks agents put in front of it (spinner frames, ✳, ✻,
    /// bullets), and nothing that is only a path: a directory says where, not what.
    static func cleanedTerminalTitle(_ title: String) -> String? {
        var text = oneLine(title)
        while let first = text.unicodeScalars.first, isStatusMark(first) {
            text = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, !text.hasPrefix("~"), !text.hasPrefix("/") else { return nil }
        return text
    }

    private static func isStatusMark(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value)
            || "✳✻✽✶✢·•*●○◐◑◒◓⏺".unicodeScalars.contains(scalar)
    }
}
