import DesignSystem
import SwiftUI

struct AgentToolsSection: View {
    var body: some View {
        Section {
            Text("Claude Code and Codex get hooks and terminal tools when started in a \(Brand.name) pane.")
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.textSecondary)
                .settingAnchor("agent-tools")
        } header: {
            Text("Agent Tools")
        } footer: {
            Text("Agents can read panes in their session. Driving your panes requires your approval.")
        }
    }
}
