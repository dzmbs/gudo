import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Everything the command palette offers, in the order shown with an empty query: what needs the
/// user first, then tabs, then actions (Raycast's "suggestions first", Ghostty's action list).
enum PaletteCommands {
    /// The palette's placeholder for each mode.
    static func placeholder(_ mode: PaletteMode) -> String {
        switch mode {
        case .commands: "Execute a command…"
        case .goToTab: "Go to a tab on any host…"
        case .newTabOnHost: "New tab on…"
        }
    }

    static func all(workspace: Workspace, model: WindowModel) -> [PaletteCommand] {
        switch model.paletteMode {
        case .goToTab: return tabs(model: model, section: nil)
        case .newTabOnHost: return newTabHosts(model: model)
        case .commands: break
        }
        var commands: [PaletteCommand] = []

        for item in model.agents.items where item.state.needsYou {
            commands.append(PaletteCommand(
                id: "agent-\(item.id)", title: needsYouTitle(item), subtitle: "\(item.agent.title) · \(item.hostName) · \(item.sessionTitle)",
                section: "Needs You", state: item.state) { model.destination = .inbox })
        }

        commands += tabs(model: model, section: "Tabs")

        let actions: [(WorkspaceAction, String)] = [
            (.newTab, "plus"), (.newTabOnHost, "plus.rectangle.on.rectangle"), (.goToTab, "arrow.right.square"),
            (.splitRight, "rectangle.split.2x1"), (.splitDown, "rectangle.split.1x2"),
            (.toggleZoom, "arrow.up.left.and.arrow.down.right"), (.closePane, "xmark"),
            (.nextTab, "chevron.right"), (.previousTab, "chevron.left"),
        ]
        for (action, image) in actions {
            commands.append(PaletteCommand(
                id: "action-\(action.title)", title: action.title, section: "Terminal", systemImage: image,
                shortcut: action.shortcut.symbols
            ) { action.perform(on: workspace, window: model) })
        }

        let tools: [(String, String, String, [String]?, () -> Void)] = [
            ("find", "Find in Scrollback", "magnifyingglass", ["⌘", "F"], { model.isSearchShown = true }),
            ("links", "Links & Paths", "link", ["⇧", "⌘", "L"], { model.sheet = .links }),
            ("diff", "Review Changes", "plusminus", nil, { model.sheet = .diff }),
            ("files", "Browse Files", "folder", nil, { model.sheet = .files }),
            ("browser", "Open Browser", "safari", nil, { model.sheet = .browser }),
            ("share", "Share Session", "person.crop.circle.badge.plus", nil, { model.sheet = .invite }),
            ("join", "Join a Session…", "person.2.badge.plus", nil, { model.joinInvite = ""; model.sheet = .join }),
            ("agent", "New Agent", "sparkle", nil, { model.sheet = .launchAgent }),
            ("inbox", "Go to Inbox", "tray", ["⇧", "⌘", "I"], { model.destination = .inbox }),
            ("hosts", "Go to Hosts", "server.rack", nil, { model.destination = .hosts }),
            ("add-host", "Add Host", "plus.circle", nil, { model.addHost() }),
            ("settings", "Settings", "gearshape", ["⌘", ","], { model.sheet = .settings }),
        ]
        for (id, title, image, keys, run) in tools {
            commands.append(PaletteCommand(id: id, title: title, section: "Go", systemImage: image, shortcut: keys, action: run))
        }

        let open = Set(model.groups.groups.map(\.id))
        for host in model.hosts.hosts where !open.contains(host.id) && !host.isLocal {
            commands.append(PaletteCommand(
                id: "host-\(host.id)", title: "Connect to \(host.name)", subtitle: host.address, section: "Hosts",
                systemImage: host.kind == .ssh ? "terminal" : host.kind == .local ? "laptopcomputer" : "server.rack") { model.hosts.connect(host.id) })
        }
        return commands
    }

    /// Every tab on every host, in the sidebar's order, searchable by name, context and host
    /// ("hetzner · claude: fix the build"), with its ⌘N.
    static func tabs(model: WindowModel, section: String?) -> [PaletteCommand] {
        let showsHost = model.groups.groups.count > 1
        var commands: [PaletteCommand] = []
        for group in model.groups.groups {
            let workspace = model.workspace(ofGroup: group.id)
            for tab in group.tabs {
                let ref = group.ref(tab.id)
                let states = tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
                let title = workspace?.title(of: tab) ?? tab.title ?? "Shell"
                let context = workspace?.context(of: tab)
                let subtitle = [showsHost || section == nil ? group.name : nil, context].compactMap(\.self).joined(separator: " · ")
                commands.append(PaletteCommand(
                    id: "tab-\(ref)", title: title, subtitle: subtitle.isEmpty ? nil : subtitle,
                    section: section, systemImage: group.isLocal ? "laptopcomputer" : group.kind == .ssh ? "terminal" : "server.rack",
                    state: states.min { $0.urgency < $1.urgency },
                    shortcut: model.groups.shortcutNumber(of: ref).map { ["⌘", "\($0)"] }
                ) { model.focus(ref) })
            }
        }
        return commands
    }

    /// ⌥⌘T: the hosts a tab can open on, the current one first, then Add Host.
    static func newTabHosts(model: WindowModel) -> [PaletteCommand] {
        let groups = model.groups.groups.sorted { a, b in (a.id == model.currentGroupId ? 0 : 1) < (b.id == model.currentGroupId ? 0 : 1) }
        var commands = groups.map { group in
            PaletteCommand(
                id: "new-tab-\(group.id)", title: group.name,
                subtitle: group.isReady || group.isLocal ? (group.tabs.count == 1 ? "1 tab" : "\(group.tabs.count) tabs") : group.status.summary,
                section: "New Tab On", systemImage: group.isLocal ? "laptopcomputer" : group.kind == .ssh ? "terminal" : "server.rack",
                badge: group.id == model.currentGroupId ? "Current" : nil
            ) { model.newTab(onGroup: group.id) }
        }
        let open = Set(groups.map(\.id))
        for host in model.hosts.hosts where !open.contains(host.id) && !host.isLocal {
            commands.append(PaletteCommand(
                id: "new-tab-connect-\(host.id)", title: host.name, subtitle: "Connect · \(host.address)", section: "Other Hosts",
                systemImage: host.kind == .ssh ? "terminal" : "server.rack"
            ) {
                model.show(.host(host.id))
                model.newTab(onGroup: host.id)
            })
        }
        commands.append(PaletteCommand(id: "new-tab-add-host", title: "Add Host…", section: "Other Hosts", systemImage: "plus.circle") {
            model.addHost()
        })
        return commands
    }

    private static func needsYouTitle(_ item: AgentItem) -> String {
        switch item.request {
        case .permission(let tool, let detail): "\(tool): \(detail)"
        case .question(let question): question
        case nil: item.summary ?? item.prompt
        }
    }
}

extension KeyboardShortcut {
    /// The glyphs macOS menus show, in their order: ⌃⌥⇧⌘ then the key.
    var symbols: [String] {
        var result: [String] = []
        if modifiers.contains(.control) { result.append("⌃") }
        if modifiers.contains(.option) { result.append("⌥") }
        if modifiers.contains(.shift) { result.append("⇧") }
        if modifiers.contains(.command) { result.append("⌘") }
        switch key {
        case .leftArrow: result.append("←")
        case .rightArrow: result.append("→")
        case .upArrow: result.append("↑")
        case .downArrow: result.append("↓")
        case .return: result.append("↩")
        case .escape: result.append("⎋")
        case .tab: result.append("⇥")
        default: result.append(String(key.character).uppercased())
        }
        return result
    }
}
