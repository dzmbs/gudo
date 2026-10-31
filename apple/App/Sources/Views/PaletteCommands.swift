import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UnnamedCore

/// Everything the command palette offers, in the order shown with an empty query: what needs the
/// user first, then tabs, then actions (Raycast's "suggestions first", Ghostty's action list).
enum PaletteCommands {
    /// The palette's placeholder for each mode.
    static func placeholder(_ mode: PaletteMode) -> String {
        switch mode {
        case .commands: "Execute a command…"
        case .goToTab: "Go to a tab on any host…"
        case .newTabOnHost: "New tab on…"
        case .splitWithHost: "Split with a pane on…"
        case .workflows: "Run a workflow…"
        case .recentlyClosed: "Reopen a closed tab…"
        }
    }

    static func all(workspace: Workspace, model: WindowModel) -> [PaletteCommand] {
        switch model.paletteMode {
        case .goToTab: return tabs(model: model, section: nil)
        case .newTabOnHost: return newTabHosts(model: model)
        case .splitWithHost: return splitHosts(model: model)
        case .workflows: return workflows(model: model)
        case .recentlyClosed: return recentlyClosed(model: model, all: true)
        case .commands: break
        }
        var commands: [PaletteCommand] = []

        for item in model.agents.items where item.state.needsYou {
            commands.append(PaletteCommand(
                id: "agent-\(item.id)", title: needsYouTitle(item), subtitle: "\(item.title) · \(item.hostName) · \(item.sessionTitle)",
                section: "Needs You", program: item.identity, state: item.state) { model.destination = .inbox })
        }

        commands += tabs(model: model, section: "Tabs")
        commands += recentlyClosed(model: model)
        commands += git(model: model)

        let actions: [(WorkspaceAction, String)] = [
            (.newTab, "plus"), (.newTabOnHost, "plus.rectangle.on.rectangle"), (.newProject, "folder.badge.plus"), (.goToTab, "arrow.right.square"),
            (.splitRight, "rectangle.split.2x1"), (.splitDown, "rectangle.split.1x2"), (.splitWithHost, "rectangle.split.2x1.fill"),
            (.toggleZoom, "arrow.up.left.and.arrow.down.right"), (.closePane, "xmark"),
            (.nextTab, "chevron.right"), (.previousTab, "chevron.left"),
            (.previousPrompt, "chevron.up"), (.nextPrompt, "chevron.down"),
        ] + (DrawingCommands.canDraw(in: workspace) ? [(.draw, "pencil.and.scribble"), (.newCanvas, "scribble.variable")] : [])
        for (action, image) in actions {
            commands.append(PaletteCommand(
                id: "action-\(action.title)", title: action.title, section: "Terminal", systemImage: image,
                shortcut: action.shortcut.symbols
            ) { action.perform(on: workspace, window: model) })
        }

        let tools: [(String, String, String, [String]?, () -> Void)] = [
            ("find", "Find in Scrollback", "magnifyingglass", ["⌘", "F"], { model.isSearchShown = true }),
            ("links", "Links & Paths", "link", ["⇧", "⌘", "L"], { model.sheet = .links }),
            ("copy-output", "Copy Last Command Output", "doc.on.clipboard", nil, { Task { await model.copyLastCommandOutput() } }),
            ("workflows", "Workflows…", "terminal", ["/"], { model.paletteMode = .workflows; model.isPaletteShown = true }),
            ("new-workflow", "New Workflow from Last Command…", "text.badge.plus", nil, { model.newWorkflowFromLastCommand() }),
            ("diff", "Review Changes", "plusminus", nil, { model.sheet = .diff }),
            ("editor", "Open in VS Code", "chevron.left.forwardslash.chevron.right", nil, { model.openEditor() }),
            ("files", "Browse Files", "folder", nil, { model.sheet = .files }),
            ("browser", "Dev Servers & Ports", "globe", nil, {
                model.browserURL = nil
                model.sheet = .browser
            }),
            ("share", "Share Session", "person.crop.circle.badge.plus", nil, { model.sheet = .invite }),
            ("sharing", "Manage Sharing…", "person.2.badge.key", nil, { model.sheet = .sharing }),
            ("join", "Join a Session…", "person.2.badge.plus", nil, { model.joinInvite = ""; model.sheet = .join }),
            ("agent", WorkspaceAction.newAgent.title, "sparkle", WorkspaceAction.newAgent.shortcut.symbols, { model.newAgent() }),
            ("inbox", "Go to Agents", Destination.inbox.systemImage, WorkspaceAction.inbox.shortcut.symbols, { model.destination = .inbox }),
            ("hosts", "Go to Hosts", "server.rack", nil, { model.destination = .hosts }),
            ("add-host", "Add Host", "plus.circle", nil, { model.addHost() }),
            ("settings", "Settings", "gearshape", ["⌘", ","], { model.sheet = .settings }),
            ("shortcuts", "Keyboard Shortcuts", "keyboard", ["⌘", "/"], { model.sheet = .shortcuts }),
            ("replays", "Session Replays", "play.rectangle.on.rectangle", nil, { model.showReplays(.all) }),
            ("two-columns", model.isTwoColumns ? "One Column" : "Two Columns", "rectangle.split.2x1", nil, { model.toggleTwoColumns() }),
            ("sidebar", model.isSidebarShown ? "Hide Sidebar" : "Show Sidebar", "sidebar.leading", ["⌘", "B"], {
                WorkspaceAction.toggleSidebar.perform(window: model)
            }),
            ("tab-bar", TabPlacement.showsTabBar ? "Hide Tab Bar When the Sidebar Is Hidden" : "Show Tab Bar When the Sidebar Is Hidden",
             "rectangle.topthird.inset.filled", nil, { TabPlacement.showsTabBar.toggle() }),
        ]
        for (id, title, image, keys, run) in tools + model.editorPaletteExtras + model.browserPaletteExtras {
            commands.append(PaletteCommand(id: id, title: title, section: "Go", systemImage: image, shortcut: keys, action: run))
        }

        for port in model.ports.ports where port.isHTTP {
            commands.append(PaletteCommand(
                id: "port-\(port.port)", title: "Open localhost:\(port.port)",
                subtitle: [port.process, port.pane].compactMap { $0 }.joined(separator: " · "), section: "Ports",
                systemImage: "globe") { Task { await model.openPort(port) } })
        }

        let open = Set(model.groups.groups.map(\.id))
        for host in model.hosts.hosts where !open.contains(host.id) && !host.isLocal {
            commands.append(PaletteCommand(
                id: "host-\(host.id)", title: "Connect to \(host.name)", subtitle: host.address, section: "Hosts",
                systemImage: host.kind == .ssh ? "terminal" : host.kind == .local ? "laptopcomputer" : "server.rack") { model.hosts.connect(host.id) })
        }
        return commands
    }

    /// Tabs hidden at launch and recently closed ones, newest first, each with where it was and
    /// when it closed: what History ▸ Recently Closed lists, searchable.
    static func recentlyClosed(model: WindowModel, all: Bool = false) -> [PaletteCommand] {
        let section = all ? nil : "Recently Closed"
        var commands: [PaletteCommand] = []
        let hidden = model.groups.restorableTabs.count
        if hidden > 0 {
            commands.append(PaletteCommand(
                id: "restore-previous", title: "Reopen Previous Tabs", subtitle: hidden == 1 ? "1 tab" : "\(hidden) tabs",
                section: section, systemImage: "arrow.counterclockwise") { model.restoreHiddenTabs() })
        }
        if !model.idleTabs.isEmpty {
            commands.append(PaletteCommand(
                id: "close-idle", title: "Close \(model.idleTabs.count) Idle Tabs", subtitle: "Untouched for \(IdleTabRule.days) days",
                section: section, systemImage: "moon.zzz") { model.closeIdleTabs() })
        }
        for (index, entry) in model.recentlyClosed.tabs.prefix(all ? RecentlyClosed.limit : 5).enumerated() {
            let program = entry.agent.map { ProgramCatalog.identity(process: $0) }
            commands.append(PaletteCommand(
                id: "closed-\(entry.id)", title: entry.title, subtitle: entry.subtitle(), section: section,
                systemImage: program == nil ? "terminal" : nil, program: program,
                shortcut: index == 0 ? WorkspaceAction.reopenClosedTab.shortcut.symbols : nil
            ) { model.reopenClosed(entry.id) })
        }
        return commands
    }

    /// Every tab on every host, in the sidebar's order, searchable by name, project, context and
    /// host ("api · hetzner · claude: fix the build"), with its ⌘N.
    static func tabs(model: WindowModel, section: String?) -> [PaletteCommand] {
        let showsHost = model.groups.groups.count > 1
        let projects = Dictionary(model.projects.flatMap { project in project.tabs.map { ($0, project.name) } }, uniquingKeysWith: { a, _ in a })
        return model.groups.tabs.compactMap { ref -> PaletteCommand? in
            let shortcut = model.groups.shortcutNumber(of: ref).map { ["⌘", "\($0)"] }
            if ref.hostId == HostGroups.mixedId {
                guard let mixed = model.composites.tab(ref.tab) else { return nil }
                let subtitle = [projects[ref], mixed.hosts.map(model.groupName).joined(separator: " + ")].compactMap(\.self).joined(separator: " · ")
                return PaletteCommand(
                    id: "tab-\(ref)", title: model.title(ofMixedTab: mixed), subtitle: subtitle, section: section,
                    systemImage: "rectangle.split.2x1",
                    program: mixed.isEditorOnly ? .vscode : mixed.isBrowserOnly ? .browser : nil,
                    shortcut: shortcut
                ) { model.focus(ref) }
            }
            guard let group = model.groups.group(ref.hostId), let tab = group.tabs.first(where: { $0.id == ref.tab }) else { return nil }
            let workspace = model.workspace(ofGroup: group.id)
            let states = tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
            let title = workspace?.title(of: tab) ?? tab.title ?? "Shell"
            let context = workspace?.context(of: tab)
            let subtitle = [projects[ref], showsHost || section == nil ? group.name : nil, context].compactMap(\.self).joined(separator: " · ")
            return PaletteCommand(
                id: "tab-\(ref)", title: title, subtitle: subtitle.isEmpty ? nil : subtitle,
                section: section, program: model.programIdentity(of: tab, onGroup: group.id),
                state: states.min { $0.urgency < $1.urgency },
                shortcut: shortcut
            ) { model.focus(ref) }
        }
    }

    /// The focused pane's worktree: pull request actions (Merge respects GitHub's merge state and
    static func git(model: WindowModel) -> [PaletteCommand] {
        let git = model.git
        guard let wt = git.worktree else { return [] }
        var commands: [PaletteCommand] = []
        let section = "Git · \(wt.displayBranch)"
        if let pr = wt.visiblePR, pr.state == .open {
            if pr.mergeBlocker == nil {
                commands.append(PaletteCommand(
                    id: "git-merge", title: "Merge PR #\(pr.number)",
                    subtitle: "\(GitSettings.name(GitSettings.mergeStrategy)) · \(pr.title)", section: section,
                    systemImage: "arrow.triangle.merge", badge: pr.mergeState == .unstable ? "Optional check failed" : nil
                ) { git.requestMerge(wt) })
            }
            if pr.hasRerunnableFailures {
                commands.append(PaletteCommand(
                    id: "git-rerun", title: "Re-run Failed Checks", subtitle: pr.checksSummary.words, section: section,
                    systemImage: "arrow.clockwise") { git.rerunFailed(wt) })
            }
        }
        if let pr = wt.visiblePR {
            commands.append(PaletteCommand(
                id: "git-open-pr", title: "Open PR #\(pr.number) on GitHub", subtitle: pr.title, section: section,
                systemImage: "arrow.up.right.square", shortcut: ["⌃", "⌘", "G"]) { git.openOnGitHub(pr) })
        } else if !wt.main, case .ready = git.gh {
            commands.append(PaletteCommand(
                id: "git-create-pr", title: "Create Pull Request", subtitle: "Push \(wt.displayBranch) and open it (gh pr create --fill)",
                section: section, systemImage: "arrow.triangle.pull") { git.createPR(wt) })
        }
        if let port = git.port(of: wt) {
            commands.append(PaletteCommand(
                id: "git-open-port", title: "Open localhost:\(String(port))", subtitle: "\(wt.displayBranch)'s PORT, in the browser",
                section: section, systemImage: "globe") { git.openPort(of: wt) })
        }
        commands.append(PaletteCommand(
            id: "git-checkout-pr", title: "Check Out Pull Request…", subtitle: "Into a new worktree", section: section,
            systemImage: "arrow.down.to.line") { git.isCheckoutPromptShown = true })
        for script in git.scripts(for: wt) {
            commands.append(PaletteCommand(
                id: "git-run-\(script.id)", title: "Run: \(script.name)", subtitle: script.command, section: section,
                systemImage: script.systemImage, shortcut: script == git.defaultScript(for: wt) ? ["⌘", "R"] : nil,
                badge: "Script") { git.run(script, in: wt) })
        }
        if !wt.main {
            commands.append(PaletteCommand(
                id: "git-archive", title: "Archive Worktree", subtitle: wt.name, section: section, systemImage: "archivebox",
                badge: "Archive") { git.archive(wt) })
            commands.append(PaletteCommand(
                id: "git-delete", title: "Delete Worktree…", subtitle: wt.name, section: section, systemImage: "trash",
                badge: "Remove") { git.delete(wt) })
        }
        for archived in git.archived where archived.repo == wt.repo {
            commands.append(PaletteCommand(
                id: "git-restore-\(archived.id)", title: "Restore \(archived.branch ?? (archived.path as NSString).lastPathComponent)",
                subtitle: "Archived \(Date(timeIntervalSince1970: Double(archived.archivedAtMs) / 1000).formatted(.relative(presentation: .named)))\(archived.savedChanges ? " · with changes" : "")",
                section: section, systemImage: "tray.and.arrow.up") { git.restore(archived) })
        }
        return commands
    }

    /// "/": the focused pane's workflows, its repository's first, each with its description and
    /// where it comes from; then New Workflow from Last Command.
    static func workflows(model: WindowModel) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        let list = model.workflowList
        for workflow in list?.workflows ?? [] {
            let section = workflow.scope == .repo ? "Repository · \(list?.repoName ?? "this repository")" : "Global"
            let arguments = workflow.arguments.map(\.name).joined(separator: ", ")
            commands.append(PaletteCommand(
                id: "workflow-\(workflow.id)", title: workflow.name,
                subtitle: [workflow.description ?? workflow.command, arguments.isEmpty ? nil : "{\(arguments)}"]
                    .compactMap(\.self).joined(separator: " · "),
                section: section, systemImage: workflow.scope == .repo ? "folder" : "globe",
                badge: workflow.sourceLabel) { model.choose(workflow) })
        }
        if let problems = list?.problems, !problems.isEmpty {
            let names = problems.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            commands.append(PaletteCommand(
                id: "workflow-problems", title: problems.count == 1 ? "1 workflow file could not be read" : "\(problems.count) workflow files could not be read",
                subtitle: "\(names): \(problems[0].message)", section: "Workflows", systemImage: "exclamationmark.triangle") {})
        }
        if list?.workflows.isEmpty ?? true {
            let dir = ".\(Brand.name.lowercased())/workflows"
            commands.append(PaletteCommand(
                id: "workflow-none", title: model.workflowTarget == nil ? "Workflows come from a host running the helper" : list == nil ? "Reading workflows…" : "No workflows yet",
                subtitle: "YAML files in the repository's \(dir) or ~/.config/\(Brand.name.lowercased())/workflows", section: "Workflows",
                systemImage: "info.circle") {})
        }
        commands.append(PaletteCommand(
            id: "new-workflow", title: "New Workflow from Last Command…", section: "Workflows", systemImage: "text.badge.plus"
        ) { model.newWorkflowFromLastCommand() })
        return commands
    }

    /// ⌥⌘T: the hosts a tab can open on, the current one first, then Add Host.
    /// Split with Host…: every other open host that can take a pane now, then Add Host.
    static func splitHosts(model: WindowModel) -> [PaletteCommand] {
        var commands = model.splitWithHostCandidates.map { group in
            PaletteCommand(
                id: "split-\(group.id)", title: group.name,
                subtitle: group.isLocal ? "This device's shell" : group.kind == .ssh ? "SSH" : nil,
                section: "Split With", systemImage: group.isLocal ? "laptopcomputer" : group.kind == .ssh ? "terminal" : "server.rack"
            ) { model.split(withHost: group.id) }
        }
        if commands.isEmpty {
            commands.append(PaletteCommand(
                id: "split-add-host", title: "Add Host…", subtitle: "Pair or connect another host to split with it",
                section: "Split With", systemImage: "plus.circle") { model.addHost() })
        }
        return commands
    }

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
