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
    static let slot: CGFloat = 16
    #else
    static let slot: CGFloat = 18
    #endif
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
            .controlFill(ControlState(isHovered: hovered, isSelected: selected))
            .padding(.horizontal, DS.Space.s)
            .onHover { hovered = $0 }
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
    }
}

/// A tab's worktree on its row's second line: the branch, with the pull request's glyph when
/// there is one.
struct TabBranchLabel: View {
    let worktree: WorktreeState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: worktree.visiblePR?.kind.systemImage ?? "arrow.triangle.branch")
                .imageScale(.small)
            Text(worktree.displayBranch)
                .truncationMode(.middle)
        }
        .lineLimit(1)
    }
}

/// A tab's worktree at its row's trailing edge: uncommitted lines and the pull request number.
struct TabGitBadges: View {
    let worktree: WorktreeState
    let selected: Bool

    var body: some View {
        HStack(spacing: DS.Space.row) {
            DiffStat(added: worktree.added, removed: worktree.removed, selected: selected)
            if let pr = worktree.visiblePR {
                Text("#\(pr.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .fixedSize()
    }

    /// "main, +121 −2, pull request 42 open, 3 successful checks".
    static func accessibilityValue(_ worktree: WorktreeState) -> String {
        var parts = ["branch \(worktree.displayBranch)"]
        if worktree.added > 0 || worktree.removed > 0 { parts.append("+\(worktree.added) −\(worktree.removed)") }
        if let pr = worktree.visiblePR { parts.append("pull request \(pr.number) \(pr.stateWord), \(pr.checksSummary.words)") }
        return parts.joined(separator: ", ")
    }
}

/// A repository whose worktrees have no tab here: one quiet line that shows them under it.
struct RepoFoldRow: View {
    let repo: RepoSidebar.Repo
    let fold: WorktreeFold
    let host: String
    let expanded: Bool
    let toggle: () -> Void
    @Environment(WindowModel.self) private var model
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: GitRow.slot)
                    Text(repo.name)
                        .font(SidebarFont.subtitle.weight(.medium))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Text("\(fold.folded.count) more")
                        .fixedSize()
                        .font(SidebarFont.subtitle)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                }
                .foregroundStyle(DS.Palette.textTertiary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(repo.name), \(fold.foldedTitle)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides them" : "Shows them")
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
        .modifier(GitRowStyle(selected: false))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("more-worktrees-\(repo.name)")
    }
}

/// A worktree without a tab: its branch, changes and pull request; a tap opens a tab in it.
struct WorktreeRow: View {
    let worktree: WorktreeState
    let host: String
    @Environment(WindowModel.self) private var model

    var body: some View {
        let pr = worktree.visiblePR
        let port = model.git.port(of: worktree, host: host)
        Button {
            model.git.openTab(in: worktree.path, name: worktree.name, host: host)
        } label: {
            HStack(spacing: 6) {
                BranchGlyph(pr: pr)
                    .frame(width: GitRow.slot)
                VStack(alignment: .leading, spacing: 0) {
                    Text(worktree.displayBranch)
                        .font(SidebarFont.title)
                        .foregroundStyle(DS.Palette.textSecondary)
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
                        .font(SidebarFont.subtitle)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                TabGitBadges(worktree: worktree, selected: false)
            }
            .modifier(GitRowStyle(selected: false, depth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(port: port))
        .accessibilityHint("Opens a tab in it")
        .accessibilityIdentifier("worktree-row-\(worktree.displayBranch)")
        .rowActions(RowActions(.worktree(isMain: worktree.main)), id: "worktree-\(host)-\(worktree.path)", name: worktree.displayBranch) { action in
            switch action {
            case .archiveWorktree: model.git.archive(worktree, host: host)
            case .deleteWorktree: model.git.delete(worktree, host: host)
            default: break
            }
        } menu: {
            WorktreeMenu(worktree: worktree, host: host)
        }
    }

    private func accessibilityLabel(port: UInt16?) -> String {
        var parts = [worktree.subtitle, port.map { "PORT \($0)" }].compactMap(\.self)
        parts.insert(TabGitBadges.accessibilityValue(worktree), at: 0)
        return parts.joined(separator: ", ")
    }
}

private struct BranchGlyph: View {
    let pr: PullRequest?

    var body: some View {
        Image(systemName: pr?.kind.systemImage ?? "arrow.triangle.branch")
            .font(SidebarFont.subtitle.weight(.medium))
            .foregroundStyle(pr.map { AnyShapeStyle($0.kind.color) } ?? AnyShapeStyle(DS.Palette.textSecondary))
            .opacity(DS.Opacity.mutedGlyph)
            .overlay(alignment: .bottomTrailing) {
                if let pr, pr.state == .open {
                    CheckBadge(pr.checkKinds, selected: false)
                        .font(.system(size: 7, weight: .black))
                        .frame(width: 10, height: 10)
                        .offset(x: 3, y: 3)
                }
            }
            .help(pr.map { "Pull request \($0.stateWord.lowercased()) · \($0.checksSummary.words)" } ?? "No linked pull request")
    }
}

private struct WorktreeMenu: View {
    let worktree: WorktreeState
    let host: String
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
            Button("Open localhost:\(String(port))", systemImage: "globe") { git.openPort(of: worktree, host: host) }
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
            Group {
                HStack(spacing: 6) {
                    SectionDot(DS.Palette.attention)
                    Text("Needs you").font(SidebarFont.section).foregroundStyle(DS.Palette.textSecondary)
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
                                Text(title).font(SidebarFont.title).lineLimit(1)
                                Text([item.host, item.context].compactMap(\.self).joined(separator: " · "))
                                    .font(SidebarFont.subtitle)
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
