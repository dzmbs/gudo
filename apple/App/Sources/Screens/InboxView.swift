import DesignSystem
import SwiftUI

/// Agent Inbox: needs you / running / finished with inline actions (stub).
struct InboxView: View {
    let feed: any AgentFeed
    var onLaunch: () -> Void = {}

    var body: some View { Text("Inbox") }
}

/// Start Claude Code or Codex on a host (stub).
struct LaunchAgentSheet: View {
    let feed: any AgentFeed
    let hosts: [HostSummary]

    var body: some View { Text("Launch Agent") }
}
