import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import GudoCore
#if os(macOS)
import AppKit
#endif

enum GitRow {
    #if os(macOS)
    static let title = Font.body
    static let slot: CGFloat = 16
    #else
    static let title = Font.subheadline
    static let slot: CGFloat = 18
    #endif
    static let subtitle = Font.footnote
    static let indent: CGFloat = 14
    static let selectedFill = DS.Palette.selectedFill
}

/// ⌘ is held (Mac): rows swap their accessories for their ⌘N, without reflowing.
@MainActor
@Observable
final class CommandKeyState {
    static let shared = CommandKeyState()
    private(set) var held = false
    #if os(macOS)
    @ObservationIgnored private var monitor: Any?
    #endif

    private init() {
        #if os(macOS)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            MainActor.assumeIsolated { self?.commandChanged(held) }
            return event
        }
        #endif
    }

    #if os(macOS)
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// The delay keeps quickly typed ⌘-shortcuts from flashing the hints.
    private func commandChanged(_ down: Bool) {
        pending?.cancel()
        guard down else {
            if held { withAnimation(DS.Motion.quick) { held = false } }
            return
        }
        pending = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: CommandKeyState.delay)) != nil, let self, !self.held else { return }
            withAnimation(DS.Motion.quick) { self.held = true }
        }
    }
    #endif

    static let delay = Duration.milliseconds(750)
}

private struct GitRowStyle: ViewModifier {
    let selected: Bool
    var depth = 0
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, DS.Space.m + CGFloat(depth) * GitRow.indent)
            .padding(.trailing, DS.Space.m)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
            .frame(minHeight: 32)
            #endif
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(DS.Palette.ink.opacity(selected ? ChromePalette.fillLevels.selected : hovered ? ChromePalette.fillLevels.hover : 0)))
            .padding(.horizontal, DS.Space.s)
            .onHover { hovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }
}

struct RepoSectionHeader: View {
    let repo: RepoSidebar.Repo
    let host: String
    @Environment(WindowModel.self) private var model
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(repo.name)
                .font(DS.Font.section)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            Button("New Agent in \(repo.name)", systemImage: "plus") {
                model.newAgent(onGroup: host, repo: repo.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(DS.Palette.textSecondary)
            #if os(macOS)
            .opacity(hovered ? 1 : 0)
            #else
            .opacity(DS.Opacity.mutedGlyph)
            #endif
            .help("New Agent in \(repo.name) (⇧⌘N)")
            .accessibilityIdentifier("repo-new-agent-\(repo.name)")
        }
        .padding(.leading, DS.Space.l + DS.Space.xs)
        .padding(.trailing, DS.Space.l)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repo-header-\(repo.name)")
    }
}

/// With one tab the row is that tab; with none it is quiet and opens a tab.
struct WorktreeRow: View {
    let worktree: WorktreeState
    let host: String
    /// The tab the row stands for (its only tab, or the first of several).
    let tab: Tab?
    let number: Int?
    let isActive: Bool
    let agent: DesignSystem.AgentState?
    @Environment(WindowModel.self) private var model

    var body: some View {
        let pr = worktree.visiblePR
        let idle = tab == nil
        let port = model.git.port(of: worktree, host: host)
        Button {
            if let tab {
                withAnimation(DS.Motion.snappy) { model.focus(TabRef(hostId: host, tab: tab.id)) }
            } else {
                model.git.openTab(in: worktree.path, name: worktree.name, host: host)
            }
        } label: {
            HStack(spacing: 6) {
                BranchGlyph(pr: pr, selected: isActive)
                    .frame(width: GitRow.slot)
                VStack(alignment: .leading, spacing: 0) {
                    Text(worktree.displayBranch)
                        .font(GitRow.title)
                        .foregroundStyle(idle ? DS.Palette.textSecondary : DS.Palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if worktree.subtitle != nil || port != nil {
                        HStack(spacing: DS.Space.xs) {
                            if let subtitle = worktree.subtitle {
                                Text(subtitle).truncationMode(.middle)
                            }
                            if let port {
                                Text(verbatim: ":\(port)")
                                    .monospacedDigit()
                                    .layoutPriority(1)
                                    .help("PORT \(port): what $PORT is in this worktree's panes")
                            }
                        }
                        .font(GitRow.subtitle)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                Accessories(worktree: worktree, pr: pr, agent: isActive ? nil : agent, selected: isActive, number: number)
            }
            .modifier(GitRowStyle(selected: isActive))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(port: port))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("worktree-row-\(worktree.displayBranch)")
        .rowActions(RowActions(.worktree(isMain: worktree.main)), id: "worktree-\(host)-\(worktree.path)", name: worktree.displayBranch) { action in
            switch action {
            case .archiveWorktree: model.git.archive(worktree, host: host)
            case .deleteWorktree: model.git.delete(worktree, host: host)
            default: break
            }
        } menu: {
            WorktreeMenu(worktree: worktree, host: host, tab: tab)
        }
    }

    private func accessibilityLabel(port: UInt16?) -> String {
        var parts = [worktree.displayBranch]
        if let subtitle = worktree.subtitle { parts.append(subtitle) }
        if let port { parts.append("PORT \(port)") }
        if worktree.added > 0 || worktree.removed > 0 { parts.append("+\(worktree.added) −\(worktree.removed)") }
        if let pr = worktree.visiblePR { parts.append("pull request \(pr.number) \(pr.stateWord), \(pr.checksSummary.words)") }
        if let agent { parts.append(agent.title) }
        return parts.joined(separator: ", ")
    }
}

struct WorktreeTabRow: View {
    let tab: Tab
    let host: String
    let number: Int?
    let isActive: Bool
    let agent: DesignSystem.AgentState?
    @Environment(WindowModel.self) private var model

    var body: some View {
        let workspace = model.workspace(ofGroup: host)
        let title = workspace?.title(of: tab) ?? tab.title ?? "Shell"
        Button {
            withAnimation(DS.Motion.snappy) { model.focus(TabRef(hostId: host, tab: tab.id)) }
        } label: {
            HStack(spacing: 6) {
                TabLeadingMark(program: model.programIdentity(of: tab, onGroup: host), state: isActive ? nil : agent)
                Text(title)
                    .font(GitRow.subtitle)
                    .foregroundStyle(isActive ? DS.Palette.text : DS.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.xs)
                if CommandKeyState.shared.held, let number {
                    Text("⌘\(number)").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .modifier(GitRowStyle(selected: isActive, depth: 1))
        }
        .buttonStyle(.plain)
        .tabDrag(TabRef(hostId: host, tab: tab.id), model: model)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("worktree-tab-\(number ?? 0)")
        .rowActions(actions, id: "\(host)/\(tab.id)", name: title) { action in
            let ref = TabRef(hostId: host, tab: tab.id)
            switch action {
            case .rename:
                model.focus(ref)
                workspace?.renamingTab = tab.id
            case .closeTab:
                model.closeTab(ref, undoable: actions.undoable.contains(.closeTab))
            default: break
            }
        } menu: {
            if let workspace { MergeIntoTabMenu(workspace: workspace, tab: tab.id) }
        }
    }

    private var actions: RowActions {
        RowActions(.terminalTab(isBusy: agent == .working || agent == .blocked))
    }
}

private struct BranchGlyph: View {
    let pr: PullRequest?
    let selected: Bool

    var body: some View {
        Image(systemName: pr?.kind.systemImage ?? "arrow.triangle.branch")
            .font(GitRow.subtitle.weight(.medium))
            .foregroundStyle(selected || pr == nil ? AnyShapeStyle(DS.Palette.textSecondary) : AnyShapeStyle(pr!.kind.color))
            .opacity(selected ? 1 : DS.Opacity.mutedGlyph)
            .overlay(alignment: .bottomTrailing) {
                if let pr, pr.state == .open {
                    CheckBadge(pr.checkKinds, selected: selected)
                        .font(.system(size: 7, weight: .black))
                        .frame(width: 10, height: 10)
                        .offset(x: 3, y: 3)
                }
            }
            .help(pr.map { "Pull request \($0.stateWord.lowercased()) · \($0.checksSummary.words)" } ?? "No linked pull request")
    }
}

/// Fixed size so the title takes the squeeze; ⌘ held swaps it for ⌘N by opacity, without reflow.
private struct Accessories: View {
    let worktree: WorktreeState
    let pr: PullRequest?
    let agent: DesignSystem.AgentState?
    let selected: Bool
    let number: Int?

    var body: some View {
        let held = CommandKeyState.shared.held && number != nil
        ZStack(alignment: .trailing) {
            HStack(spacing: DS.Space.row) {
                DiffStat(added: worktree.added, removed: worktree.removed, selected: selected)
                if let pr {
                    Text("#\(pr.number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                if let agent {
                    AgentGlyph(state: agent)
                }
            }
            .opacity(held ? 0 : 1)
            if held, let number {
                Text("⌘\(number)").font(.caption).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .fixedSize()
    }
}

private struct WorktreeMenu: View {
    let worktree: WorktreeState
    let host: String
    let tab: Tab?
    @Environment(WindowModel.self) private var model

    var body: some View {
        let git = model.git
        Button("New Tab Here", systemImage: "plus") {
            git.openTab(in: worktree.path, name: worktree.name, host: host)
        }
        if let pr = worktree.visiblePR {
            Button("Open #\(pr.number) on GitHub", systemImage: "arrow.up.right.square") { git.openOnGitHub(pr) }
        }
        if let port = git.port(of: worktree, host: host) {
            Button("Open localhost:\(String(port))", systemImage: "globe") { git.openPort(of: worktree, host: host, tab: tab) }
        }
        let scripts = git.scripts(for: worktree)
        if !scripts.isEmpty {
            Menu("Run", systemImage: "play") {
                ForEach(scripts) { script in
                    Button(script.name, systemImage: script.systemImage) { git.run(script, in: worktree, host: host) }
                }
            }
        }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(worktree.path) }
        if let branch = worktree.branch {
            Button("Copy Branch Name", systemImage: "arrow.triangle.branch") { Pasteboard.copy(branch) }
        }
        if let port = git.port(of: worktree, host: host) {
            Button("Copy PORT", systemImage: "number") { Pasteboard.copy(String(port)) }
        }
        if let tab {
            Divider()
            Button("Rename Tab…", systemImage: "pencil") {
                model.focus(TabRef(hostId: host, tab: tab.id))
                model.workspace(ofGroup: host)?.renamingTab = tab.id
            }
            Button(RowAction.closeTab.title, systemImage: RowAction.closeTab.systemImage) {
                model.closeTab(TabRef(hostId: host, tab: tab.id), undoable: true)
            }
        }
    }
}

/// One host's tabs outside a repository, then each repository with its worktrees.
struct RepoGroupsView<LooseRow: View>: View {
    let group: HostGroup
    let sidebar: RepoSidebar
    let numbers: [TabRef: Int]
    @ViewBuilder let looseRow: (Tab) -> LooseRow
    @Environment(WindowModel.self) private var model

    var body: some View {
        let tabs = Dictionary(group.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sidebar.looseTabs, id: \.self) { id in
                if let tab = tabs[id] { looseRow(tab) }
            }
            ForEach(sidebar.repos) { repo in
                RepoSectionHeader(repo: repo, host: group.id)
                ForEach(repo.worktrees) { worktree in
                    let rowTabs = worktree.tabs.compactMap { tabs[$0] }
                    let first = rowTabs.first
                    WorktreeRow(
                        worktree: worktree.state, host: group.id, tab: first,
                        number: first.flatMap { numbers[group.ref($0.id)] },
                        isActive: rowTabs.count == 1 && first.map(isActive) == true,
                        agent: rowTabs.count == 1 ? first.flatMap(agentState) : rowTabs.compactMap(agentState).min { AgentGlyph.priority($0) < AgentGlyph.priority($1) })
                    if rowTabs.count > 1 {
                        ForEach(rowTabs) { tab in
                            WorktreeTabRow(
                                tab: tab, host: group.id, number: numbers[group.ref(tab.id)],
                                isActive: isActive(tab), agent: agentState(tab))
                        }
                    }
                }
            }
        }
        .opacity(group.showsAsLive ? 1 : 0.6)
    }

    private func isActive(_ tab: Tab) -> Bool {
        model.destination == .terminal && model.currentTab == group.ref(tab.id)
    }

    private func agentState(_ tab: Tab) -> DesignSystem.AgentState? {
        tab.root.panes
            .compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
            .min { AgentGlyph.priority($0) < AgentGlyph.priority($1) }
    }
}

/// Every tab, on every host, whose agent waits for an answer or failed, hoisted above the hosts.
struct NeedsYouSection: View {
    @Environment(WindowModel.self) private var model

    private struct Item: Identifiable {
        var ref: TabRef
        var tab: Tab
        var state: DesignSystem.AgentState
        var host: String
        var context: String?
        var id: TabRef { ref }
    }

    var body: some View {
        let items = self.items
        if !items.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SectionDot(DS.Palette.attention)
                    Text("Needs you").font(DS.Font.section).foregroundStyle(DS.Palette.textSecondary)
                }
                .padding(.leading, DS.Space.l + DS.Space.xs)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.xs)
                ForEach(items) { item in
                    let title = model.workspace(ofGroup: item.ref.hostId)?.title(of: item.tab) ?? item.tab.title ?? "Shell"
                    Button {
                        withAnimation(DS.Motion.snappy) { model.focus(item.ref) }
                    } label: {
                        HStack(spacing: 6) {
                            AgentGlyph(state: item.state).frame(width: GitRow.slot)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(title).font(GitRow.title).lineLimit(1)
                                Text([item.host, item.context].compactMap(\.self).joined(separator: " · "))
                                    .font(GitRow.subtitle)
                                    .foregroundStyle(DS.Palette.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: DS.Space.xs)
                            Text(item.state.title)
                                .font(.caption)
                                .foregroundStyle(item.state.color)
                        }
                        .modifier(GitRowStyle(selected: false))
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("needs-you-\(title)")
                }
            }
            .accessibilityIdentifier("needs-you")
        }
    }

    private var items: [Item] {
        model.groups.groups.flatMap { group -> [Item] in
            let sidebar = model.groups.repoSidebar(for: group)
            return group.tabs.compactMap { tab in
                let ref = group.ref(tab.id)
                // The tab on screen is not hoisted: you are looking at it.
                if model.destination == .terminal && model.currentTab == ref { return nil }
                let state = tab.root.panes
                    .compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
                    .min { AgentGlyph.priority($0) < AgentGlyph.priority($1) }
                guard let state, state.needsYou else { return nil }
                return Item(ref: ref, tab: tab, state: state, host: group.name, context: sidebar?.worktree(of: tab.id)?.displayBranch)
            }
        }
    }
}
