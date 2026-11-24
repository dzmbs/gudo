import DesignSystem
import GudoCore
import HostKit
import SwiftUI

#if os(iOS)
/// Where Chat's agent controls read and change a pane's agent.
struct ChatAgentControlsContext {
    let hub: DaemonWorkspace
    let pane: UInt64
    /// This device is the host's owner, the only one who may change the agent.
    let canChange: Bool
    /// A turn is running, so a change waits for it.
    let isWorking: Bool
}

extension EnvironmentValues {
    @Entry var chatAgentControls: ChatAgentControlsContext?
}

/// The agent's model, reasoning effort and permission mode, each a small menu that changes the
/// running agent: Claude Code restarts on the same conversation once its turn ends, Codex takes
/// it with the next turn. Self-contained, so the composer places it where it fits.
struct ChatAgentControls: View {
    let context: ChatAgentControlsContext
    let session: TimelineSession?
    @State private var failure: String?
    @State private var confirming: AgentConfigValues?

    var body: some View {
        let config = context.hub.agentControls[context.pane]?.config
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: DS.Space.xxs) {
                Spacer(minLength: 0)
                if let note = ChatAgentControlsText.note(config, isWorking: context.isWorking) {
                    Text(note).lineLimit(1)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .accessibilityIdentifier("chat-config-note")
                }
                if let config {
                    modelMenu(config)
                    if !config.efforts.isEmpty { effortMenu(config) }
                    if !config.modes.isEmpty { modeMenu(config) }
                }
            }
            if let failure {
                Text(failure).lineLimit(2)
                    .foregroundStyle(DS.Palette.error)
                    .accessibilityIdentifier("chat-config-failure")
            }
        }
        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        .confirmationDialog(confirmationTitle(config), isPresented: isConfirming, titleVisibility: .visible, presenting: confirming) { values in
            Button("Restart") { send(values) }
            Button("Cancel", role: .cancel) {}
        } message: { values in
            if let config { Text(ChatAgentControlsText.restartInPaneConfirmation(values, in: config).message) }
        }
        .onAppear { context.hub.watchAgentControls(pane: context.pane) }
        .onDisappear { context.hub.unwatchAgentControls(pane: context.pane) }
    }

    private var enabled: Bool { context.canChange }

    private func sectionTitle(_ config: AgentConfig) -> String {
        if case .unsupported(let reason) = config.support { return reason }
        if !context.canChange { return "Only the host's owner can change this" }
        switch config.timing {
        case .restart: return "Claude Code restarts on this conversation"
        case .nextTurn: return "Codex uses it from the next message"
        case .now: return "Changes at once"
        case .restartInPane: return "Claude Code restarts in its pane on this conversation"
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private func confirmationTitle(_ config: AgentConfig?) -> String {
        guard let config, let confirming else { return "" }
        return ChatAgentControlsText.restartInPaneConfirmation(confirming, in: config).title
    }

    private func modelMenu(_ config: AgentConfig) -> some View {
        let current = config.pending?.model ?? config.current.model
        let title = ChatAgentControlsText.modelLabel(current, in: config.models)
            ?? session?.model.map(ChatSessionControls.modelName) ?? "Model"
        return Menu {
            Section(sectionTitle(config)) {
                ForEach(config.models) { choice in
                    choiceButton(choice, isCurrent: choice.id == current) { change(AgentConfigValues(model: choice.id)) }
                        .disabled(!enabled || !config.isSupported)
                }
            }
        } label: {
            chip(title)
        }
        .menuStyle(.button)
        .buttonStyle(ChatChipButtonStyle())
        .accessibilityLabel("Model, \(title)")
        .accessibilityIdentifier("chat-model")
    }

    private func effortMenu(_ config: AgentConfig) -> some View {
        let current = config.pending?.effort ?? config.current.effort
        let title = config.efforts.first { $0.id == current }?.label ?? "Effort"
        return Menu {
            Section("Thinking effort") {
                ForEach(config.efforts) { choice in
                    choiceButton(choice, isCurrent: choice.id == current) { change(AgentConfigValues(effort: choice.id)) }
                        .disabled(!enabled || !config.isSupported)
                }
            }
        } label: {
            chip(title)
        }
        .menuStyle(.button)
        .buttonStyle(ChatChipButtonStyle())
        .accessibilityLabel("Effort, \(title)")
        .accessibilityIdentifier("chat-effort")
    }

    private func modeMenu(_ config: AgentConfig) -> some View {
        let current = config.pending?.mode ?? config.current.mode
        let mode = config.modes.first { $0.id == current }
        let title = mode?.choice.label ?? current ?? "Mode"
        let risk = mode?.risk ?? .unknown
        return Menu {
            Section(sectionTitle(config)) {
                ForEach(config.modes) { option in
                    choiceButton(option.choice, isCurrent: option.id == current) { change(AgentConfigValues(mode: option.id)) }
                        .disabled(!enabled || !config.isSupported)
                }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: ChatAgentControlsText.shield(risk))
                    .foregroundStyle(Self.riskStyle(risk))
                chip(title)
            }
        }
        .menuStyle(.button)
        .buttonStyle(ChatChipButtonStyle())
        .accessibilityLabel("Permission mode, \(title)")
        .accessibilityIdentifier("chat-mode")
    }

    private static func riskStyle(_ risk: AgentModeRisk) -> ChromeStyle {
        switch risk {
        case .bypass: DS.Palette.attention
        case .plans: DS.Palette.info
        case .asks, .edits, .automatic, .unknown: DS.Palette.textTertiary
        }
    }

    private func choiceButton(_ choice: AgentChoice, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isCurrent { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
            if !choice.detail.isEmpty { Text(choice.detail) }
        }
    }

    private func chip(_ title: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(verbatim: title).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private func change(_ values: AgentConfigValues) {
        guard context.canChange else { return }
        if let config = context.hub.agentControls[context.pane]?.config, ChatAgentControlsText.confirmsChange(config) {
            confirming = values
        } else {
            send(values)
        }
    }

    private func send(_ values: AgentConfigValues) {
        guard context.canChange else { return }
        failure = nil
        let (hub, pane) = (context.hub, context.pane)
        Task {
            do { try await hub.setAgentConfig(pane: pane, change: values) } catch {
                failure = ChatAgentControlsText.failure(error)
            }
        }
    }
}

#endif

/// What the agent controls say, apart from the views so it can be tested.
nonisolated enum ChatAgentControlsText {
    /// When a waiting change reaches the agent.
    static func note(_ config: AgentConfig?, isWorking: Bool) -> String? {
        guard let config, config.pending != nil else { return nil }
        switch config.timing {
        case .restart, .restartInPane: return isWorking ? "Applies after this turn" : "Restarting with the change"
        case .nextTurn: return "Applies next turn"
        case .now: return "Changing"
        }
    }

    /// Whether a change replaces what the user typed in the pane, so Chat asks first.
    static func confirmsChange(_ config: AgentConfig) -> Bool {
        config.timing == .restartInPane
    }

    /// What Chat asks before restarting a Claude Code started by hand.
    static func restartInPaneConfirmation(_ values: AgentConfigValues, in config: AgentConfig) -> (title: String, message: String) {
        let choice = values.model.flatMap { model in modelLabel(model, in: config.models) }
            ?? values.mode.flatMap { mode in config.modes.first { $0.id == mode }?.choice.label }
            ?? values.effort.flatMap { effort in config.efforts.first { $0.id == effort }?.label }
        let title = choice.map { "Restart Claude Code with \($0)?" } ?? "Restart Claude Code?"
        let message = "You started Claude Code in this pane. Once it is idle it stops, and claude --resume starts it again there on this conversation, in place of the command you typed."
        return (title, message)
    }

    /// A model's name as its picker gives it, else read from its identifier.
    static func modelLabel(_ identifier: String?, in choices: [AgentChoice]) -> String? {
        guard let identifier else { return nil }
        if let choice = choices.first(where: { $0.id == identifier }) { return choice.label }
        return ChatSessionControls.modelName(identifier)
    }

    static func shield(_ risk: AgentModeRisk) -> String {
        switch risk {
        case .bypass: "exclamationmark.shield.fill"
        case .plans: "list.bullet.clipboard"
        case .asks, .edits, .automatic, .unknown: "shield"
        }
    }

    static func failure(_ error: any Error) -> String {
        switch error {
        case WorkspaceError.Denied(let message), WorkspaceError.Unavailable(let message),
             WorkspaceError.Invalid(let message), WorkspaceError.Conflict(let message),
             WorkspaceError.Failed(let message):
            message
        default: "The change did not reach the agent."
        }
    }
}
