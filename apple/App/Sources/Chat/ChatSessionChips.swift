#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

/// The model and permission mode, quietly under the composer. Choosing a model puts Claude Code's
/// own `/model` command in the message for Send to apply. The mode only changes in Terminal:
/// Claude Code cycles it with Shift-Tab, and a key that steps through modes could land on one
/// the user did not choose.
struct ChatSessionChips: View {
    let session: TimelineSession?
    let canChooseModel: Bool
    let chooseModel: (String) -> Void

    var body: some View {
        let model = session?.model.map(ChatSessionControls.modelName)
        let mode = session?.permissionMode.map(ChatSessionControls.modeName)
        if model != nil || mode != nil {
            HStack(spacing: DS.Space.xs) {
                Spacer(minLength: 0)
                if let model {
                    Menu {
                        Section("Send applies the /model command") {
                            ForEach(ChatSessionControls.models, id: \.command) { option in
                                Button(option.title) { chooseModel(option.command) }
                            }
                        }
                    } label: { chip(model) }
                    .disabled(!canChooseModel)
                    .accessibilityLabel("Model, \(model)")
                    .accessibilityIdentifier("chat-model")
                }
                if let mode {
                    Menu {
                        Button("Shift-Tab in Terminal changes the mode") {}.disabled(true)
                    } label: { chip(mode) }
                    .accessibilityLabel("Permission mode, \(mode)")
                    .accessibilityIdentifier("chat-mode")
                }
            }
            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private func chip(_ title: String) -> some View {
        Text(verbatim: title).lineLimit(1)
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: DS.Size.touchTarget)
            .contentShape(.rect)
    }
}
#endif
