import HostKit

/// The model and permission mode Chat shows under its composer, named as people say them.
nonisolated enum ChatSessionControls {
    struct ModelOption: Equatable, Sendable {
        let title: String
        let command: String
    }

    struct ModeOption: Equatable, Sendable {
        let mode: TimelinePermissionModeTag
        let title: String
        let detail: String
    }

    /// Claude Code's own aliases: `/model <alias>` picks the newest of each family.
    static let models = [
        ModelOption(title: "Default", command: "/model default"),
        ModelOption(title: "Opus", command: "/model opus"),
        ModelOption(title: "Sonnet", command: "/model sonnet"),
        ModelOption(title: "Haiku", command: "/model haiku"),
    ]

    /// Every mode Claude Code records, in the order Shift-Tab steps through the common ones.
    static let modes = [
        ModeOption(mode: .default, title: "Ask", detail: "Asks before edits and commands"),
        ModeOption(mode: .acceptEdits, title: "Accept edits", detail: "Edits files without asking"),
        ModeOption(mode: .plan, title: "Plan", detail: "Plans first and changes nothing"),
        ModeOption(mode: .auto, title: "Auto", detail: "Asks only when it matters"),
        ModeOption(mode: .dontAsk, title: "Don't ask", detail: "Declines anything not allowed"),
        ModeOption(mode: .bypassPermissions, title: "Bypass", detail: "Runs everything without asking"),
    ]

    /// The aliases with the session's own family first, so the menu opens on what is running.
    static func modelChoices(current identifier: String?) -> [ModelOption] {
        let family = identifier.map(modelName)?.split(separator: " ").first.map(String.init)
        guard let family, let index = models.firstIndex(where: { $0.title == family }) else { return models }
        var ordered = models
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

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
        case .known(let tag): modes.first { $0.mode == tag }?.title ?? tag.rawValue
        case .unknown(let value): value
        }
    }
}
