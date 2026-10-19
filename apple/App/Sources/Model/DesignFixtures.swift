import DesignSystem
import Foundation
import PaneLayout

/// Puts a window into a known state for design review and screenshots:
/// `-screen <name>` (UserDefaults argument domain). Names are listed in docs/DESIGN.md
/// "Screenshots". Does nothing in normal launches.
enum DesignFixtures {
    static func apply(_ screen: String?, workspace: Workspace, model: WindowModel) async {
        guard let screen else { return }
        // A host (`-restoreLastTarget YES` with a saved host) has no panes until its layout arrives.
        for _ in 0..<100 where workspace.focusedPane == nil && workspace.isRemote {
            try? await Task.sleep(for: .milliseconds(100))
        }
        switch screen {
        case "welcome":
            for tab in workspace.session.tabs { workspace.apply(.closeTab(tab.id)) }
            return
        case "single":
            name(workspace)
            return
        case "live-splits":
            // A real host's tab split in three, names and titles left as they are.
            if let tab = workspace.session.activeTab, tab.root.panes.count == 1 {
                workspace.apply(.split(tab.focused, .horizontal))
                try? await Task.sleep(for: .milliseconds(800))
                if let second = workspace.focusedPane { workspace.apply(.split(second, .vertical)) }
            }
            return
        default:
            break
        }
        // left as it is.
        if !LaunchOptions.mock {
            // Screenshot seeds (apple/scripts/w3-screenshots.sh): text typed into the focused
            // pane, an agent started with a first prompt.
            let defaults = UserDefaults.standard
            if let text = defaults.string(forKey: "typeOnStart"), let id = workspace.focusedPane, let pane = workspace.panes[id] {
                Data(text.replacingOccurrences(of: "\\n", with: "\r").utf8).withUnsafeBytes { pane.backend.write($0) }
                try? await Task.sleep(for: .seconds(1))
            }
            if let prompt = defaults.string(forKey: "seedAgent"), let host = workspace.hostId {
                _ = try? await model.agents.launch(AgentLaunchRequest(agent: .claude, hostId: host, prompt: prompt))
                try? await Task.sleep(for: .seconds(4))
            }
            switch screen {
            case "inbox":
                model.destination = .inbox
                return
            case "files", "diff", "links", "browser", "launchAgent":
                if let route = SheetRoute(rawValue: screen) { model.sheet = route }
                return
            case "editor":
                model.openEditor()
                return
            case "seed":
                return
            default:
                break
            }
        }

        splits(workspace)
        switch screen {
        case "hosts": model.destination = .hosts
        case "inbox": model.destination = .inbox
        case "palette": model.isPaletteShown = true
        case "search":
            model.isSearchShown = true
            model.searchNeedle = "error"
        case "keybar":
            #if os(iOS)
            // Show the software keyboard with the key bar on the focused pane.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                if let id = workspace.focusedPane { _ = workspace.panes[id]?.view.becomeFirstResponder() }
            }
            #endif
        case "reconnect": model.connectionOverride = .reconnecting(attempt: 3, since: Date(timeIntervalSinceNow: -14))
        case "overlays":
            let panes = workspace.session.activeTab?.root.panes ?? []
            if panes.count > 2 {
                workspace.notices[panes[1]] = PaneNotice(exit: ("Process exited with code **1** after 2.4s. Press any key to close.", true))
                workspace.notices[panes[2]] = PaneNotice(bell: true, hoveredURL: "https://github.com/ghostty-org/ghostty/pull/8497")
                workspace.notices[panes[0]] = PaneNotice(secureInput: true)
            }
        default:
            if screen == "ticket" { model.addHost(mode: .ticket) } else if let route = SheetRoute(rawValue: screen) { model.sheet = route }
        }
    }

    /// Tab 1: a shell beside Claude, Codex below it; two more tabs.
    private static func splits(_ workspace: Workspace) {
        guard let first = workspace.focusedPane else { return }
        workspace.apply(.split(first, .horizontal))
        if let second = workspace.focusedPane { workspace.apply(.split(second, .vertical)) }
        workspace.apply(.focus(first))
        name(workspace)
        workspace.apply(.newTab)
        if let id = workspace.session.activeTabId { workspace.apply(.rename(id, "cargo test")) }
        workspace.apply(.newTab)
        if let id = workspace.session.activeTabId { workspace.apply(.rename(id, "build-01 · journalctl")) }
        if let tab = workspace.session.tabs.first { workspace.selectTab(tab.id) }
    }

    private static func name(_ workspace: Workspace) {
        if let id = workspace.session.activeTabId { workspace.apply(.rename(id, "~/projects/unnamed")) }
    }
}
