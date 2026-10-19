import HostKit
import SwiftUI

/// By default only what Claude Code and Codex themselves write or print on the host; the toggle
/// also lets the host ask the providers' own usage endpoints with its sign-in.
struct AgentsSettingsSection: View {
    @AppStorage(AgentUsageSettings.apiFallbackKey) private var apiFallback = false

    var body: some View {
        Section {
            Toggle("Check Usage with Your Claude and Codex Sign-In", isOn: $apiFallback)
                .accessibilityIdentifier("settings-usage-api-fallback")
                .onChange(of: apiFallback) { DaemonWorkspace.usageSettingsChanged() }
        } header: {
            Text("Agent Usage")
        } footer: {
            Text("""
            Usage meters read what Claude Code and Codex record on each host: Claude's status line in \
            sessions started from this app, Codex's session logs, and their own usage commands. When \
            those say nothing, this lets the host ask Anthropic's and OpenAI's usage pages with the \
            sign-in already on the host. Those pages are not a published interface and may change. \
            Your sign-in never leaves the host; only the percentages reach this device.
            """)
        }
    }
}
