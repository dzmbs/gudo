import DesignSystem
import PaneLayout
import SwiftUI

/// Everything the command palette offers, in the order shown with an empty query: what needs the
/// user first, then tabs, then actions (Raycast's "suggestions first", Ghostty's action list).
enum PaletteCommands {
    static func all(workspace: Workspace, model: WindowModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []

        for item in model.agents.items where item.state.needsYou {
            commands.append(PaletteCommand(
                id: "agent-\(item.id)", title: needsYouTitle(item), subtitle: "\(item.agent.title) · \(item.hostName) · \(item.sessionTitle)",
                section: "Needs You", state: item.state) { model.destination = .inbox })
        }

        for (index, tab) in workspace.session.tabs.enumerated() {
            let states = tab.root.panes.compactMap { model.paneStatus.state(of: $0.description) }
            commands.append(PaletteCommand(
                id: "tab-\(tab.id)", title: workspace.title(of: tab),
                subtitle: tab.root.panes.count > 1 ? "\(tab.root.panes.count) panes" : nil,
                section: "Tabs", systemImage: "terminal", state: states.min { $0.urgency < $1.urgency },
                shortcut: index < 8 ? ["⌘", "\(index + 1)"] : nil
            ) {
                model.destination = .terminal
                workspace.selectTab(tab.id)
            })
        }

        let actions: [(WorkspaceAction, String)] = [
            (.newTab, "plus"), (.splitRight, "rectangle.split.2x1"), (.splitDown, "rectangle.split.1x2"),
            (.toggleZoom, "arrow.up.left.and.arrow.down.right"), (.closePane, "xmark"),
            (.nextTab, "chevron.right"), (.previousTab, "chevron.left"),
        ]
        for (action, image) in actions {
            commands.append(PaletteCommand(
                id: "action-\(action.title)", title: action.title, section: "Terminal", systemImage: image,
                shortcut: action.shortcut.symbols) { action.perform(on: workspace) })
        }

        let tools: [(String, String, String, [String]?, () -> Void)] = [
            ("find", "Find in Scrollback", "magnifyingglass", ["⌘", "F"], { model.isSearchShown = true }),
            ("links", "Links & Paths", "link", ["⇧", "⌘", "L"], { model.sheet = .links }),
            ("copy-output", "Copy Last Command Output", "doc.on.clipboard", nil, { Task { await model.copyLastCommandOutput() } }),
            ("diff", "Review Changes", "plusminus", nil, { model.sheet = .diff }),
            ("editor", "Open in VS Code", "chevron.left.forwardslash.chevron.right", nil, { model.openEditor() }),
            ("files", "Browse Files", "folder", nil, { model.sheet = .files }),
            ("browser", "Dev Servers & Ports", "network", nil, {
                model.browserURL = nil
                model.sheet = .browser
            }),
            ("share", "Share Session", "person.crop.circle.badge.plus", nil, { model.sheet = .invite }),
            ("agent", "New Agent", "sparkle", nil, { model.sheet = .launchAgent }),
            ("inbox", "Go to Inbox", "tray", ["⇧", "⌘", "I"], { model.destination = .inbox }),
            ("hosts", "Go to Hosts", "server.rack", nil, { model.destination = .hosts }),
            ("add-host", "Add Host", "plus.circle", nil, { model.addHost() }),
            ("settings", "Settings", "gearshape", ["⌘", ","], { model.sheet = .settings }),
        ]
        for (id, title, image, keys, run) in tools {
            commands.append(PaletteCommand(id: id, title: title, section: "Go", systemImage: image, shortcut: keys, action: run))
        }

        for port in model.ports.ports where port.isHTTP {
            commands.append(PaletteCommand(
                id: "port-\(port.port)", title: "Open localhost:\(port.port)",
                subtitle: [port.process, port.pane].compactMap { $0 }.joined(separator: " · "), section: "Ports",
                systemImage: "globe") { Task { await model.openPort(port) } })
        }

        for host in model.hosts.hosts {
            commands.append(PaletteCommand(
                id: "host-\(host.id)", title: "Connect to \(host.name)", subtitle: host.address, section: "Hosts",
                systemImage: host.kind == .ssh ? "terminal" : host.kind == .local ? "laptopcomputer" : "server.rack") { model.hosts.connect(host.id) })
        }
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
