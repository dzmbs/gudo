import DesignSystem
import Foundation
import PaneLayout
import SwiftUI

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
        case "programs":
            // The first pane opens a moment after the window on iOS.
            for _ in 0..<50 where workspace.focusedPane == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // One window model per scene: the workspace given is the one on screen.
            programs(workspace)
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
        case "agent-toast":
            // Two agents on another host start needing you and finish, a moment apart: the toast
            // stack (`AgentToasts`), approve from it, ⇧⌘A.
            guard let feed = model.agents as? MockAgentFeed else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(DS.Motion.snappy) {
                feed.simulate("a3", state: .blocked, request: .permission(tool: "Bash", detail: "cargo bench -p renderer"))
            }
            try? await Task.sleep(for: .seconds(0.6))
            withAnimation(DS.Motion.snappy) { feed.simulate("a4", state: .done, summary: "The reconnect test waited on a stale timer; fixed.") }
        case "reconnect": model.connectionOverride = .reconnecting(attempt: 3, since: Date(timeIntervalSinceNow: -14))
        case "overlays":
            let panes = workspace.session.activeTab?.root.panes ?? []
            if panes.count > 2 {
                workspace.notices[panes[1]] = PaneNotice(exit: ("Process exited with code **1** after 2.4s. Press any key to close.", true))
                workspace.notices[panes[2]] = PaneNotice(bell: true, hoveredURL: "https://github.com/ghostty-org/ghostty/pull/8497")
                workspace.notices[panes[0]] = PaneNotice(secureInput: true)
            }
        default:
            if screen == "ticket" { model.addHost(mode: .ticket) } else if screen == "themes" { model.sheet = .settings } else if let route = SheetRoute(rawValue: screen) { model.sheet = route }
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

    /// tab that needs input (its glyph replaces the mark), the first tab selected.
    private static func programs(_ workspace: Workspace) {
        let tabs: [(name: String, program: String, state: AgentState?)] = [
            ("~/projects/unnamed", "claude", .working), ("notes.txt", "vim", nil), ("build-01", "htop", nil),
            ("scratch", "python3.12", nil), ("review", "codex", .blocked), ("README.md", "nvim", nil),
            ("Cargo.toml", "hx", nil), ("work", "tmux", nil), ("history", "git", nil), ("load", "btop", nil),
            ("console", "irb", nil), ("~", "-zsh", nil),
            ("search", "gemini", nil), ("pr", "copilot", nil), ("init.el", "emacs", nil), ("api", "docker", nil),
            ("prod", "kubectl", nil), ("web", "node", nil), ("bench", "bun", nil), ("tools", "deno", nil),
            ("server", "go", nil), ("build", "cargo", nil), ("check", "rustc", nil), ("db", "psql", nil),
            ("cache", "redis-cli", nil),
        ]
        var fixture: [String: (program: String, state: AgentState?)] = [:]
        // `-fixtureTabs N`: the first N only (the tab strip has room for about six).
        let count = UserDefaults.standard.integer(forKey: "fixtureTabs")
        for (index, tab) in tabs.prefix(count > 0 ? count : tabs.count).enumerated() {
            if index > 0 { workspace.apply(.newTab) }
            guard let id = workspace.session.activeTabId, let pane = workspace.focusedPane else { continue }
            workspace.apply(.rename(id, tab.name))
            fixture[pane.description] = (tab.program, tab.state)
        }
        if let first = workspace.session.tabs.first {
            workspace.selectTab(first.id)
            // Claude beside a shell, so the pane headers show their marks too.
            workspace.apply(.split(first.focused, .horizontal))
            workspace.apply(.focus(first.focused))
        }
        MockPaneStatus.fixture = fixture
    }

    private static func name(_ workspace: Workspace) {
        if let id = workspace.session.activeTabId { workspace.apply(.rename(id, "~/projects/unnamed")) }
    }
}
