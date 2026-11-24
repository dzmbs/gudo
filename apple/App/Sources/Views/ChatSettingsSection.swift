import DesignSystem
import SwiftUI

/// Settings › Agents: how Chat shows finished turns and what Send does while an agent works.
struct ChatSettingsSection: View {
    @AppStorage(ChatPreferences.Key.collapsesTurns) private var collapsesTurns = true
    @AppStorage(ChatPreferences.Key.sendWhileWorking) private var sendWhileWorking = ChatPreferences.SendWhileWorking.queue.rawValue

    var body: some View {
        Section {
            Toggle("Fold Finished Turns", isOn: $collapsesTurns)
                .accessibilityIdentifier("settings-chat-fold-turns")
                .settingAnchor("chat-fold-turns")
            Picker("While the Agent Works, Send", selection: $sendWhileWorking) {
                ForEach(ChatPreferences.SendWhileWorking.allCases, id: \.rawValue) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .accessibilityIdentifier("settings-chat-send-while-working")
            .settingAnchor("chat-send-while-working")
        } header: {
            Text("Chat")
        } footer: {
            Text("""
            A folded turn keeps its reply in view and puts what the agent did before it on one line. \
            Hold Send, or press Option-Return, to do the other.
            """)
        }
    }
}
