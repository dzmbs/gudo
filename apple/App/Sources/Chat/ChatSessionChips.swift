#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

/// The model and permission mode under the composer, each a small menu. With a helper that
/// offers agent controls they change the running agent (`ChatAgentControls`). Otherwise choosing
/// a model puts Claude Code's own `/model` command in the message for Send to apply; Codex and pi
/// only show their model. The mode then only changes in Terminal: Claude Code cycles it with
/// Shift-Tab, and a key that steps through modes could land on one the user did not choose, so
/// the menu shows every mode and checks the current one.
struct ChatSessionChips: View {
    let session: TimelineSession?
    let canChooseModel: Bool
    let chooseModel: (String) -> Void
    @Environment(\.chatAgentControls) private var agentControls

    var body: some View {
        if let agentControls, agentControls.hub.offersAgentControls {
            ChatAgentControls(context: agentControls, session: session)
        } else {
            readOnlyChips
        }
    }

    @ViewBuilder private var readOnlyChips: some View {
        let model = session?.model.map(ChatSessionControls.modelName)
        let mode = session?.permissionMode
        if model != nil || mode != nil {
            HStack(spacing: DS.Space.xxs) {
                Spacer(minLength: 0)
                if let model, !ChatSessionControls.offersModelAliases(session?.agent) {
                    Text(verbatim: model).lineLimit(1)
                        .padding(.horizontal, DS.Space.s)
                        .frame(minHeight: DS.Size.touchTarget)
                        .accessibilityLabel("Model, \(model)")
                        .accessibilityIdentifier("chat-model")
                } else if let model {
                    modelMenu(model)
                }
                if let mode { modeMenu(mode) }
            }
            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func modelMenu(_ model: String) -> some View {
        Menu {
            Section {
                Button(model, systemImage: "checkmark") {}
            }
            Section(canChooseModel ? "Switch with /model, then Send" : "Switch from an empty message") {
                ForEach(ChatSessionControls.modelChoices(current: session?.model), id: \.command) { option in
                    Button(option.title) { chooseModel(option.command) }
                        .disabled(!canChooseModel)
                }
            }
        } label: {
            chip(model)
        }
        .menuStyle(.button)
        .buttonStyle(ChatChipButtonStyle())
        .accessibilityLabel("Model, \(model)")
        .accessibilityIdentifier("chat-model")
    }

    private func modeMenu(_ mode: TimelinePermissionMode) -> some View {
        let title = ChatSessionControls.modeName(mode)
        return Menu {
            Section("Change with Shift-Tab in Terminal") {
                if case .unknown = mode {
                    Button(title, systemImage: "checkmark") {}
                }
                ForEach(ChatSessionControls.modes, id: \.mode) { option in
                    let isCurrent = mode == .known(option.mode)
                    Button {} label: {
                        if isCurrent { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                        Text(option.detail)
                    }
                    .disabled(!isCurrent)
                }
            }
        } label: {
            chip(title)
        }
        .menuStyle(.button)
        .buttonStyle(ChatChipButtonStyle())
        .accessibilityLabel("Permission mode, \(title)")
        .accessibilityIdentifier("chat-mode")
    }

    private func chip(_ title: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Text(verbatim: title).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(DS.Font.captionDetail).foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

/// A chip's label with the shared press fill, inside a 44 pt target.
struct ChatChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? DS.Palette.textSecondary : DS.Palette.textTertiary)
            .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
            .controlFill(ControlState(isPressed: configuration.isPressed, isEnabled: isEnabled),
                         in: RoundedRectangle.rounded(DS.Radius.field))
            .frame(minHeight: DS.Size.touchTarget)
            .contentShape(.rect)
            .hoverEffect(.highlight)
    }
}
#endif
