import DesignSystem
import Foundation
import HostKit
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
        case "projects": projects(model)
        case "inbox": model.destination = .inbox
        case "palette": model.isPaletteShown = true
        case "host-switcher":
            // Once the toolbar's button exists to anchor it.
            try? await Task.sleep(for: .seconds(1))
            model.isHostSwitcherShown = true
        case "palette-search":
            model.isSearchShown = true
            model.searchNeedle = "error"
            model.isPaletteShown = true
        case "goto":
            model.paletteMode = .goToTab
            model.isPaletteShown = true
        case "palette-workflows":
            model.paletteMode = .workflows
            model.isPaletteShown = true
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
        case "program-status":
            // A program other than Claude or Codex reports its own status (OSC 7501): pi asks a
            // question beside Claude at work. A status only, no approval card.
            let panes = workspace.session.activeTab?.root.panes ?? []
            guard panes.count > 2 else { return }
            MockPaneStatus.fixture = [
                panes[0].description: ("zsh", nil),
                panes[1].description: ("pi", .blocked),
                panes[2].description: ("claude", .working),
            ]
            MockPaneStatus.details = [panes[1].description: "Which framework, React or Vue? · 40%"]
        case "toast":
            try? await Task.sleep(for: .seconds(1))
            model.toasts.show(Toast("Closed “cargo test”", systemImage: "xmark.circle.fill", action: Toast.Action("Undo") {}))
        case "browser-page":
            // The in-app browser on a page (a local one: no network), its chrome in view.
            let page = "<html><body style='font:17px -apple-system;margin:40px'><h1>Dev server</h1><p>localhost:5173 · pnpm dev</p></body></html>"
            model.browserURL = URL(string: "data:text/html;charset=utf-8," + (page.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
            model.sheet = .browser
        case "start-page":
            // A new browser tab on the host whose dev servers turn up after it opens.
            let history = BrowserHistory.shared
            if history.entries.isEmpty {
                for (url, title) in [("https://ghostty.org/docs", "Ghostty Docs"), ("https://github.com", "GitHub"), ("https://developer.apple.com", "Apple Developer")] {
                    history.record(URL(string: url)!, title: title)
                }
            }
            if let ports = model.ports as? MockPortSource {
                let found = ports.ports
                ports.hostId = "studio"
                ports.ports = []
                // Once the splits above have landed: a page's view made mid-animation is made twice.
                try? await Task.sleep(for: .seconds(1))
                model.openBrowser(URL(string: "about:blank")!, hostId: ports.hostId, placement: .tab)
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    ports.ports = found
                }
            }
        case "presence-notice":
            // Someone arrives in a shared session (`-mockPresence YES`).
            try? await Task.sleep(for: .seconds(1))
            if let session = workspace.multiplayer {
                model.toasts.show(PresenceNotices.toast(arrived: ["Mira Holt"], in: session))
            }
        case "port-offer":
            // The dev-server offer with a banner over it: both clear of the panes' top bars.
            try? await Task.sleep(for: .seconds(1))
            if let ports = model.ports as? MockPortSource { ports.offer = ports.ports.first }
            model.toasts.show(Toast("Copied localhost:5173", systemImage: "doc.on.doc"))
        case "toast-error":
            try? await Task.sleep(for: .seconds(1))
            model.toasts.show(Toast("Couldn't reach devbox: connection refused", systemImage: "exclamationmark.triangle.fill", style: .failure))
        case "reconnect": model.connectionOverride = .reconnecting(attempt: 3, since: Date(timeIntervalSinceNow: -14))
        case "overlays":
            let panes = workspace.session.activeTab?.root.panes ?? []
            if panes.count > 2 {
                workspace.notices[panes[1]] = PaneNotice(exit: ("Process exited with code **1** after 2.4s. Press any key to close.", true))
                workspace.notices[panes[2]] = PaneNotice(bell: true, hoveredURL: "https://github.com/ghostty-org/ghostty/pull/8497")
                workspace.notices[panes[0]] = PaneNotice(secureInput: true)
            }
        case "file-preview": model.sheet = .files
        default:
            if screen == "ticket" { model.addHost(mode: .ticket) } else if screen == "themes" { model.sheet = .settings } else if let route = SheetRoute(rawValue: screen) { model.sheet = route }
        }
    }

    /// Tab 1: a shell beside Claude, Codex below it; two more tabs.
    /// Two daemons and a plain-SSH host beside this device, their tabs in two projects that
    /// span hosts, a few left loose.
    static func projects(_ model: WindowModel) {
        let hosts: [(HostRecord, [String])] = [
            (HostRecord(id: "fixture-studio", name: "studio", kind: .daemon, daemonId: "fixture-a"), ["api-server", "claude", "logs"]),
            (HostRecord(id: "fixture-hetzner", name: "hetzner", kind: .daemon, daemonId: "fixture-b"), ["web", "db-migrate", "deploy"]),
            (HostRecord(id: "fixture-box", name: "box", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "box", identity: .password)), ["htop"]),
        ]
        for (record, tabs) in hosts {
            model.app.hosts.attachPreview(record, connection: PreviewConnection(tabs: tabs))
            try? model.groups.open(record.id)
        }
        func ref(_ host: String, _ name: String) -> TabRef? {
            guard let group = model.groups.group(host), let tab = group.tabs.first(where: { $0.title == name }) else { return nil }
            return group.ref(tab.id)
        }
        let app = [ref("fixture-studio", "api-server"), ref("fixture-hetzner", "web"), ref("fixture-studio", "claude")].compactMap(\.self)
        let infra = [ref("fixture-hetzner", "deploy"), ref("fixture-box", "htop")].compactMap(\.self)
        model.newProject(from: app, name: "acme-app")
        model.newProject(from: infra, name: "infra")
    }

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
