import DesignSystem
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The agents in the menu bar (Settings › Notifications, off by default): its icon is the most
/// urgent state across every host, its menu the agents that need you, most urgent first.
enum MenuBarAgents {
    static let key = "menu-bar-agents"

    /// The agents that need you, the most urgent first and the longest waiting first within a state.
    static func needingYou(_ items: [AgentItem]) -> [AgentItem] {
        items.filter { $0.state.needsYou && !$0.isCommand }
            .sorted { ($0.state.urgency, $0.since) < ($1.state.urgency, $1.since) }
    }

    /// The icon: the most urgent state's symbol (shape alone, as the menu bar draws it in one
    /// colour), the agent glyph when nothing reports.
    static func symbol(for items: [AgentItem]) -> String {
        guard let state = AgentState.mostUrgent(items.filter { !$0.isCommand }.map(\.state)), state != .idle, state != .unknown else {
            return "sparkle"
        }
        return state.symbol
    }
}

#if os(macOS)
/// The feed the menu bar reads: one for the app, not a window's, so it works with every window
/// closed. Made the first time the menu bar shows it.
@MainActor
final class MenuBarAgentFeed {
    static let shared = MenuBarAgentFeed()

    @ObservationIgnored private var made: (any AgentFeed)?

    var feed: any AgentFeed {
        if let made { return made }
        let feed: any AgentFeed = LaunchOptions.mock ? MockAgentFeed() : LiveAgentFeed(hosts: AppModel.shared.hosts)
        made = feed
        return feed
    }
}

struct MenuBarAgentsLabel: View {
    var body: some View {
        let feed = MenuBarAgentFeed.shared.feed
        let waiting = MenuBarAgents.needingYou(feed.items).count
        Image(systemName: MenuBarAgents.symbol(for: feed.items))
            .accessibilityLabel(waiting == 0 ? "Agents" : "Agents, \(waiting) need you")
    }
}

struct MenuBarAgentsMenu: View {
    var body: some View {
        let feed = MenuBarAgentFeed.shared.feed
        let waiting = MenuBarAgents.needingYou(feed.items)
        if waiting.isEmpty {
            Text("Nothing needs you")
        } else {
            Section(waiting.count == 1 ? "1 Needs You" : "\(waiting.count) Need You") {
                ForEach(waiting) { item in
                    Button {
                        open(item)
                    } label: {
                        Label {
                            Text([item.title, item.sessionTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                            Text(item.state.pillTitle)
                        } icon: {
                            item.identity.image
                        }
                    }
                }
            }
        }
        let working = feed.items.filter { $0.state == .working && !$0.isCommand }.count
        if working > 0 {
            Text(working == 1 ? "1 working" : "\(working) working")
        }
        Divider()
        Button("Show Agents") {
            NSApp.activate()
            ActiveWindow.model?.destination = .inbox
        }
    }

    private func open(_ item: AgentItem) {
        NSApp.activate()
        if let hostId = item.hostId, let pane = item.paneId {
            AppNotifications.openPane(hostId: hostId, pane: pane)
        } else {
            ActiveWindow.model?.destination = .inbox
        }
    }
}
#endif
