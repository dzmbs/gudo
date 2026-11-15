import HostKit

/// The model and permission mode Chat shows under its composer, named as people say them.
nonisolated enum ChatSessionControls {
    struct ModelOption: Equatable, Sendable {
        let title: String
        let command: String
    }

    /// Claude Code's own aliases: `/model <alias>` picks the newest of each family.
    static let models = [
        ModelOption(title: "Default", command: "/model default"),
        ModelOption(title: "Opus", command: "/model opus"),
        ModelOption(title: "Sonnet", command: "/model sonnet"),
        ModelOption(title: "Haiku", command: "/model haiku"),
    ]

    /// "claude-opus-4-5-20251101" reads "Opus 4.5", "claude-3-5-sonnet-20241022" "Sonnet 3.5".
    static func modelName(_ identifier: String) -> String {
        var parts = identifier.lowercased().split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts.removeAll { $0.count == 8 && $0.allSatisfy(\.isNumber) }
        let family = parts.first { $0.first?.isLetter == true }
        let version = parts.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard let family, !version.isEmpty, parts.count == version.count + 1 else { return identifier }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + version.joined(separator: ".")
    }

    static func modeName(_ mode: TimelinePermissionMode) -> String {
        switch mode {
        case .known(.default): "Ask"
        case .known(.acceptEdits): "Accept edits"
        case .known(.plan): "Plan"
        case .known(.dontAsk): "Don't ask"
        case .known(.bypassPermissions): "Bypass"
        case .known(.auto): "Auto"
        case .unknown(let value): value
        }
    }
}
