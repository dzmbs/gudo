import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

// MARK: - Sidebar (vertical tabs)

/// Hosts on top, then one group per host the window shows (this device, each paired daemon, each
/// plain-SSH host), each with its connection dot, its tabs and its agents, and a footer with the
/// connection and settings. Every host is live at once: clicking any tab on any host switches to
/// it at once, without the Hosts screen and without reconnecting. Tab numbers run across hosts
/// (⌘1…⌘9). Selection is a quiet fill, not the accent: color stays reserved for state.
///
/// Drawn by hand (a scroll view of rows), not a system `List`: the system sidebar list paints its
/// own material (white or grey next to a dark terminal on the Mac, an inset card on iPad); this one
struct WorkspaceSidebar: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        let groups = model.groups.groups
        let numbers = Dictionary(uniqueKeysWithValues: model.groups.tabs.enumerated().map { ($1, $0 + 1) })
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    destinationRow(.inbox, title: "Inbox", systemImage: "tray") {
                        CountBadge(model.needsYouCount)
                    }
                    destinationRow(.hosts, title: "Hosts", systemImage: "server.rack") {
                        Text("\(model.hosts.hosts.count)").font(DS.Font.meta).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .padding(.top, DS.Space.s)

                NeedsYouSection()

                // Tabs whose panes live on several hosts, at the window's top.
                MixedSidebarSection(numbers: numbers)

                ForEach(groups) { group in
                    HostGroupSection(group: group, numbers: numbers)
                }

                if groups.isEmpty {
                    NoHostsRow()
                }
            }
            .padding(.bottom, DS.Space.l)
            .animation(DS.Motion.snappy, value: model.groups.collapsed)
        }
        .scrollIndicators(.never)
        // Dense rows in a fixed column: they grow with Dynamic Type up to accessibility 1
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .chromeContent()
        .background(DS.Palette.sidebar, ignoresSafeAreaEdges: .all)
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        #endif
        .overlay(alignment: .bottomLeading) { ConnectionProbe() }
    }

    private func destinationRow(_ destination: Destination, title: String, systemImage: String, @ViewBuilder trailing: () -> some View) -> some View {
        let selected = model.destination == destination
        return Button {
            withAnimation(DS.Motion.snappy) { model.destination = destination }
        } label: {
            ListRow(Text(title)) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? DS.Palette.text : DS.Palette.textSecondary)
            } trailing: {
                trailing()
            }
            .sidebarRow(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(title.lowercased())")
    }
}

/// The sidebar's width: the user's (dragged) width, widened as Dynamic Type grows so its
/// rows keep their titles and state words on one line.
enum SidebarWidth {
    static let range: ClosedRange<Double> = 200...360
    static let standard = 248.0

    static func effective(_ stored: Double, for size: DynamicTypeSize) -> Double {
        let extra: Double = switch size {
        case ...DynamicTypeSize.large: 0
        case .xLarge: 12
        case .xxLarge: 24
        case .xxxLarge: 44
        default: 72
        }
        return min(max(stored, range.lowerBound) + extra, range.upperBound + 72)
    }
}

extension View {
    /// A sidebar row: 12 pt insets in a full-width hit area, and a soft selection fill (radius 8,
    func sidebarRow(selected: Bool) -> some View {
        modifier(SidebarRowStyle(selected: selected))
    }

    /// A section title in the sidebar, aligned with the rows' text.
    func sidebarHeader() -> some View {
        padding(.horizontal, DS.Space.l + DS.Space.xs)
            .padding(.top, DS.Space.xl)
            .padding(.bottom, DS.Space.row)
    }
}

private struct SidebarRowStyle: ViewModifier {
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(DS.Palette.ink.opacity(selected ? ChromePalette.fillLevels.selected : hovered ? ChromePalette.fillLevels.hover : 0)))
            #if os(iOS)
            // The iPad pointer takes the row's own rounded shape (as the git rows do).
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: DS.Radius.control))
            .hoverEffect(.highlight)
            #endif
            .padding(.horizontal, DS.Space.s)
            .onHover { hovered = $0 }
    }
}

struct SelectionFill: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.control)
            .fill(DS.Palette.selectedFill.opacity(isSelected ? 1 : 0))
            .padding(.horizontal, DS.Space.s)
    }
}

extension HostGroup {
    /// The host's link in the design system's words (a dot and a word per state).
    var connectionState: ConnectionState {
        // A fixed `since`: the value must not change between renders (animations key on it).
        if isLocal { return .connected }
        if case .idle = status { return .disconnected }
        return ConnectionState(status, since: .distantPast)
    }

    var systemImage: String {
        switch kind {
        case .local: "laptopcomputer"
        case .daemon: "server.rack"
        case .ssh: "terminal"
        }
    }
}

/// One host: a header (disclosure, connection dot, name, + on hover), its state in words while it
/// is not live, then its tabs and its agents. The header's tap collapses the group.
private struct HostGroupSection: View {
    let group: HostGroup
    let numbers: [TabRef: Int]
    @Environment(WindowModel.self) private var model

    var body: some View {
        let collapsed = model.groups.collapsed.contains(group.id)
        VStack(alignment: .leading, spacing: 0) {
            HostGroupHeader(group: group, collapsed: collapsed)
            // Agent plan usage, one quiet line per agent, aligned with the host's name.
            if group.kind == .daemon || LaunchOptions.fakeUsage {
                HostUsageMeters(hostId: group.id, hostName: group.name)
                    .padding(.leading, DS.Space.l + 16 + DS.Space.s)
                    .padding(.trailing, DS.Space.gap10)
                    .padding(.bottom, DS.Space.xs)
            }
            if !collapsed {
                VStack(spacing: 0) {
                    // A daemon's tabs the git way once it has sent its repositories
                    // (Git/GitSidebar.swift): loose tabs, then repository → worktree.
                    if let sidebar = model.groups.repoSidebar(for: group) {
                        RepoGroupsView(group: group, sidebar: sidebar, numbers: numbers) { tab in
                            let ref = group.ref(tab.id)
                            TabRow(tab: tab, ref: ref, number: numbers[ref] ?? 0, group: group)
                        }
                    } else {
                        ForEach(group.tabs) { tab in
                            let ref = group.ref(tab.id)
                            TabRow(tab: tab, ref: ref, number: numbers[ref] ?? 0, group: group)
                        }
                    }
                    if group.tabs.isEmpty {
                        GroupPlaceholder(group: group)
                    }
                }
                GroupAgents(group: group, numbers: numbers)
            }
        }
        .transition(.opacity)
    }
}

private struct HostGroupHeader: View {
    let group: HostGroup
    let collapsed: Bool
    @Environment(WindowModel.self) private var model
    @State private var hovered = false
    @State private var showsAgents = false

    var body: some View {
        let state = group.connectionState
        let live = group.isLocal || group.status.isLive
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s) {
                // Status UX §3.2: the host's icon (replaced by its state glyph while the link is
                // Terminal. No dots, no status text.
                ConnectionGlyph(
                    state,
                    healthy: Image(systemName: group.isLocal ? "laptopcomputer" : "server.rack")
                        .foregroundStyle(DS.Palette.textSecondary).opacity(DS.Opacity.mutedGlyph))
                    // The header's own text style, so the glyph grows with Dynamic Type.
                    .font(DS.Font.section.weight(.regular))
                    .imageScale(.small)
                    .frame(minWidth: 16)
                    .help(group.failure ?? (live ? group.name : state.title))
                Text(group.name)
                    .font(DS.Font.section)
                    // Headers stay quiet; the rows under them lead.
                    .foregroundStyle(live ? DS.Palette.textSecondary : DS.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The name takes the squeeze, never the badges and + beside it.
                    .layoutPriority(-1)
                if group.kind == .ssh {
                    // Plain SSH: tabs do not outlive the connection (no daemon to keep them).
                    Text("SSH")
                        .font(DS.Font.badge)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, 1)
                        .fixedSize()
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Palette.textTertiary, lineWidth: 0.5))
                        .help("Plain SSH: tabs end with the connection. Install the helper to keep them.")
                }
                Spacer(minLength: DS.Space.xs)
                if collapsed, !group.tabs.isEmpty {
                    Text("\(group.tabs.count)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .contentTransition(.numericText())
                }
                // The host's agents at a glance (§3.4 aggregate: blocked > error > done > working).
                if let agents = aggregateAgentState {
                    HoverPopover(isPresented: $showsAgents) {
                        AgentGlyph(state: agents)
                            .frame(minWidth: 22, minHeight: 22)
                            .contentShape(.rect)
                    } content: {
                        HostAgentsPopover(group: group) { showsAgents = false }
                    }
                    .buttonStyle(.plain)
                    .help("Agents on \(group.name)")
                    .accessibilityIdentifier("host-agents-\(group.name)")
                }
                Button("New Terminal on \(group.name)", systemImage: "plus") { model.newTab(onGroup: group.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bar)
                    .font(.callout)
                    // Always there (a host with no tabs must never look like a dead end); quieter
                    // until hover on the Mac.
                    .opacity(canOpen ? (plusEmphasized ? 1 : 0.45) : 0)
                    .disabled(!canOpen)
                    .help("New Terminal on \(group.name)")
                    .accessibilityIdentifier("new-tab-\(group.name)")
            }
        }
        .popover(isPresented: Binding(
            get: { model.usageDetailHost == group.id },
            set: { if !$0, model.usageDetailHost == group.id { model.usageDetailHost = nil } })
        ) {
            UsageDetailView(hostName: group.name, report: model.usage.usage(forHost: group.id))
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.gap10)
        .padding(.top, DS.Space.m)
        .padding(.bottom, DS.Space.xs)
        .contentShape(.rect)
        .onTapGesture { withAnimation(DS.Motion.snappy) { model.groups.toggleCollapsed(group.id) } }
        .onHover { hovered = $0 }
        .contextMenu { GroupMenu(group: group, collapsed: collapsed) }
        .animation(DS.Motion.overlay, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(state.title)")
        .accessibilityValue(state.title)
        .accessibilityHint(collapsed ? "Shows its tabs" : "Hides its tabs")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("host-group-\(group.name)")
        .accessibilityAction(named: "New Tab") { model.newTab(onGroup: group.id) }
    }

    private var canOpen: Bool { group.isLocal || group.isReady }

    private var plusEmphasized: Bool {
        #if os(macOS)
        hovered
        #else
        true
        #endif
    }

    /// The most urgent agent state across the host's panes, nil when nothing reports.
    private var aggregateAgentState: AgentState? {
        let states = group.tabs.flatMap(\.root.panes).compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
        return states.filter { $0 != .idle && $0 != .unknown }.min { AgentGlyph.priority($0) < AgentGlyph.priority($1) }
    }
}

/// A host's agents at a glance (the header's glyph, on hover): one row each with its glyph,
private struct HostAgentsPopover: View {
    let group: HostGroup
    let onSelect: () -> Void
    @Environment(WindowModel.self) private var model

    var body: some View {
        let numbers = Dictionary(uniqueKeysWithValues: model.groups.tabs.enumerated().map { ($1, $0 + 1) })
        VStack(alignment: .leading) {
            Text("Agents on \(group.name)").font(.headline)
            Divider()
            ForEach(group.tabs) { tab in
                ForEach(tab.root.panes, id: \.self) { pane in
                    if let state = model.agentState(ofPane: pane, onGroup: group.id) {
                        let program = model.programIdentity(ofPane: pane, onGroup: group.id)
                        Button {
                            onSelect()
                            model.focus(pane: pane, onGroup: group.id)
                        } label: {
                            HStack(spacing: DS.Space.row) {
                                AgentGlyph(state: state)
                                Text(program.isShell ? "Agent" : program.displayName)
                                Text("\(numbers[group.ref(tab.id)] ?? 0)")
                                    .monospacedDigit()
                                    .foregroundStyle(DS.Palette.textTertiary)
                                Spacer(minLength: DS.Space.s)
                                Text(state.title).foregroundStyle(DS.Palette.textSecondary)
                            }
                            .font(.caption)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .hoverPopoverFrame()
    }
}

/// An agent's activity (status UX §3.4): working is a mini spinner in .secondary, needs input an
/// amber question mark, done a green check, failed a red cross; idle shows nothing. 12 pt in a
/// 14 pt slot so rows never jump.
struct AgentGlyph: View {
    let state: AgentState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 14 pt at the default size, growing with Dynamic Type so the glyph never clips.
    @ScaledMetric(relativeTo: .caption) private var slot: CGFloat = 14

    static func priority(_ state: AgentState) -> Int {
        switch state {
        case .blocked: 0
        case .error: 1
        case .done: 2
        case .working: 3
        case .idle, .unknown: 4
        }
    }

    var body: some View {
        Group {
            switch state {
            case .working:
                if reduceMotion {
                    Image(systemName: "circle.dotted").foregroundStyle(DS.Palette.textSecondary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            case .blocked:
                Image(systemName: "questionmark.circle.fill").foregroundStyle(DS.Palette.attention)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.done)
            case .error:
                Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Palette.error)
            case .idle, .unknown:
                EmptyView()
            }
        }
        .font(.caption)
        .frame(width: slot, height: slot)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .working: "Working"
        case .blocked: "Needs input"
        case .done: "Done"
        case .error: "Failed"
        case .idle, .unknown: ""
        }
    }
}

/// §4): the program's mark, replaced by the agent glyph while an unfocused tab has something to
/// say. Every row has the slot, so titles line up across rows and a swap never moves them. Symbols
/// draw at the muted 0.6 (the text leads); logos at the text's size, never louder than the title.
struct TabLeadingMark: View {
    let program: ProgramIdentity
    /// The agent state to show instead, nil on the focused tab (§3.4) or when nothing reports.
    let state: AgentState?

    var body: some View {
        ZStack {
            if let state, state != .idle, state != .unknown {
                AgentGlyph(state: state)
                    .transition(.opacity)
            } else {
                ProgramMark(program)
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            }
        }
        .frame(width: ProgramMark.rowSlot, height: ProgramMark.rowSlot)
        // One baseline whatever the slot holds (a spinner reports its own), so the row's number
        // and title stay on the same line in every state.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
        .animation(DS.Motion.indicator, value: state)
    }

    /// The row's spoken label: name, then the agent's state or the program, then the host.
    static func label(title: String, program: ProgramIdentity, state: AgentState?, host: String?) -> String {
        let shown = state.flatMap { $0 == .idle || $0 == .unknown ? nil : "\(program.displayName), \($0.title)" } ?? program.displayName
        return [title, shown, host].compactMap(\.self).joined(separator: ", ")
    }
}

/// A group's context menu: New Tab, collapse, retry, and closing the host in this window.
private struct GroupMenu: View {
    let group: HostGroup
    let collapsed: Bool
    @Environment(WindowModel.self) private var model

    var body: some View {
        if group.isLocal || group.isReady {
            Button("New Terminal", systemImage: "plus") { model.newTab(onGroup: group.id) }
        }
        Button(collapsed ? "Expand" : "Collapse", systemImage: collapsed ? "chevron.down" : "chevron.right") {
            withAnimation(DS.Motion.snappy) { model.groups.toggleCollapsed(group.id) }
        }
        if !group.isLocal {
            if !group.status.isLive {
                Button("Retry Now", systemImage: "arrow.clockwise") { model.hosts.retry(group.id) }
            }
            Divider()
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openInNewWindow(host: group.id) }
            if group.kind == .daemon {
                Button("Agent Usage", systemImage: "gauge.with.dots.needle.33percent") { model.usageDetailHost = group.id }
            }
            Button("Show in Hosts", systemImage: "server.rack") { model.destination = .hosts }
            Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { model.closeHost(group.id) }
        }
    }
}

/// A host with no tabs yet: what is happening, in words (never a void).
private struct GroupPlaceholder: View {
    let group: HostGroup
    @Environment(WindowModel.self) private var model

    var body: some View {
        Button {
            if group.isReady || group.isLocal {
                model.newTab(onGroup: group.id)
            } else if group.failure != nil || group.status.needsUser {
                model.hosts.retry(group.id)
            } else {
                model.show(.host(group.id))
            }
        } label: {
            HStack(spacing: DS.Space.gap10) {
                Image(systemName: group.isReady || group.isLocal ? "plus" : group.failure != nil ? "arrow.clockwise" : "ellipsis")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: 16)
                Text(group.isReady || group.isLocal ? "New Terminal" : group.failure != nil ? "Retry" : "Waiting for the host…")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .sidebarRow(selected: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(group.isReady || group.isLocal ? "new-terminal-\(group.name)" : "group-placeholder-\(group.name)")
    }
}

/// When nothing is open (iPhone and iPad before the first host): one row naming the next step.
private struct NoHostsRow: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Button { model.addHost() } label: {
            ListRow(Text("Add Host…")) {
                Image(systemName: "plus.circle").foregroundStyle(DS.Palette.textSecondary)
            } trailing: {
                EmptyView()
            }
            .sidebarRow(selected: false)
        }
        .buttonStyle(.plain)
        .padding(.top, DS.Space.l)
        .accessibilityIdentifier("sidebar-add-host")
    }
}

/// underneath in SF Mono (agent task, program, repo:branch or directory), and on the Mac its ⌘N
/// on the right. Drag to reorder within its host.
private struct TabRow: View {
    let tab: Tab
    let ref: TabRef
    let number: Int
    let group: HostGroup
    @Environment(WindowModel.self) private var model
    /// Two digits at the row's size (⌘-numbers run past 9 across hosts).
    @ScaledMetric(relativeTo: .footnote) private var numberWidth: CGFloat = 20

    var body: some View {
        let workspace = model.workspace(ofGroup: group.id)
        let isActive = model.destination == .terminal && model.currentTab == ref
        let states = tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
        let state = states.min { $0.urgency < $1.urgency }
        let title = workspace?.title(of: tab) ?? tab.title ?? "Shell"
        let context = workspace?.context(of: tab)
        let running = workspace?.runningCommand(of: tab)
        let program = model.programIdentity(of: tab, onGroup: group.id)

        Button {
            withAnimation(DS.Motion.snappy) { model.focus(ref) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.gap10) {
                Text("\(number)")
                    .font(DS.Font.sidebarSubtitle.monospacedDigit())
                    .foregroundStyle(isActive ? DS.Palette.textSecondary : DS.Palette.textTertiary)
                    // Two digits fit (⌘-numbers run past 9 across hosts), so titles stay aligned.
                    .frame(width: numberWidth, alignment: .trailing)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DS.Space.row) {
                        TabLeadingMark(program: program, state: isActive ? nil : state)
                        Text(title)
                            .font(DS.Font.sidebarTitle)
                            .lineLimit(1)
                            .truncationMode(title.hasPrefix("/") || title.hasPrefix("~") ? .head : .middle)
                            .shimmering(state == .working, text: title)
                            .foregroundStyle(.primary)
                        if tab.zoomed != nil {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    // Only a line that says something: not "~", not empty, not the title again;
                    // a shell command running a while shows with its run time.
                    let informative = context.flatMap { Self.isInformative($0, title: title) ? $0 : nil }
                    if informative != nil || running != nil {
                        TabSubtitle(context: informative, running: running)
                            // Under the title, past the mark slot and its spacing.
                            .padding(.leading, ProgramMark.rowSlot + DS.Space.row)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                if CommandKeyState.shared.held, let shortcut = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(shortcut)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .transition(.opacity)
                }
            }
            // A host that is down keeps its rows (and their last state), quieter.
            .opacity(group.status.isLive || group.isLocal ? 1 : 0.6)
            .sidebarRow(selected: isActive)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…", systemImage: "pencil") {
                model.focus(ref)
                workspace?.renamingTab = tab.id
            }
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openInNewWindow(ref) }
                .accessibilityIdentifier("open-in-new-window")
            Button("Close Tab", systemImage: "xmark", role: .destructive) { workspace?.apply(.closeTab(tab.id)) }
        }
        .tabDrag(ref, model: model)
        .dropDestination(for: String.self) { items, _ in
            // Reorder within a host; tabs live on their host, so they never cross groups.
            guard let item = items.first, let slash = item.lastIndex(of: "/"),
                  String(item[..<slash]) == group.id, let raw = UInt64(item[item.index(after: slash)...]),
                  let index = group.tabs.firstIndex(where: { $0.id == tab.id })
            else { return false }
            workspace?.apply(.moveTab(TabId(raw), to: index))
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TabLeadingMark.label(title: title, program: program, state: isActive ? nil : state, host: group.name))
        .accessibilityValue(running.map { "Running: \($0.command ?? "a command")" } ?? context ?? "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tab-row-\(number)")
    }

    /// A context line worth a second line in the row.
    static func isInformative(_ context: String, title: String) -> Bool {
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "~" && trimmed != title
    }
}

/// tabs: glyph, program, tab number, and the state word right-aligned in its color.
private struct GroupAgents: View {
    let group: HostGroup
    let numbers: [TabRef: Int]
    @Environment(WindowModel.self) private var model

    private struct Row: Identifiable {
        var number: Int
        var pane: PaneId
        var state: AgentState
        var id: PaneId { pane }
    }

    var body: some View {
        let rows: [Row] = group.tabs.flatMap { tab in
            tab.root.panes.compactMap { pane in
                model.agentState(ofPane: pane, onGroup: group.id).map { Row(number: numbers[group.ref(tab.id)] ?? 0, pane: pane, state: $0) }
            }
        }
        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    Button {
                        model.focus(pane: row.pane, onGroup: group.id)
                    } label: {
                        let program = model.programIdentity(ofPane: row.pane, onGroup: group.id)
                        // and the state word keeps its colour. The name takes the squeeze.
                        HStack(spacing: DS.Space.gap10) {
                            AgentGlyph(state: row.state)
                                .frame(minWidth: 16)
                            HStack(spacing: DS.Space.xs) {
                                ProgramMark(program, size: 12)
                                    .foregroundStyle(.primary)
                                    .opacity(DS.Opacity.mutedGlyph)
                                let name = program.isShell ? "agent" : program.displayName
                                Text(name)
                                    .font(DS.Font.sidebarSubtitle)
                                    .lineLimit(1)
                                    .shimmering(row.state == .working, text: name)
                            }
                            .layoutPriority(-1)
                            Text("\(row.number)")
                                .font(DS.Font.meta)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .fixedSize()
                            Spacer(minLength: DS.Space.xs)
                            Text(row.state.title.lowercased())
                                .font(DS.Font.meta)
                                .foregroundStyle(row.state.color)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .sidebarRow(selected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.programIdentity(ofPane: row.pane, onGroup: group.id).displayName), tab \(row.number), \(row.state.title)")
                    .accessibilityIdentifier("agent-\(group.name)-\(row.pane.rawValue)")
                }
            }
            .padding(.top, DS.Space.xs)
        }
    }
}

/// Settings, pinned under the list. No connection summary (status UX §3.2, §3.7 rule 1): each
/// host's state is on its own header, once.
/// The sidebar's footer on the Mac: Settings. On iPad Settings sits in the sidebar's top bar,
/// clear of the keyboard and its glass key bar.
private struct SidebarFooter: View {
    @Environment(WindowModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Spacer()
            Button("Settings", systemImage: "gearshape") {
                #if os(macOS)
                openSettings()
                #else
                model.sheet = .settings
                #endif
            }
            .help("Settings (⌘,)")
            .buttonStyle(.bar)
            .accessibilityIdentifier("open-settings")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }
}

/// UI tests only (`-connectionProbe YES`): every open host's connection identity and dial count,
/// so a test can assert that switching between hosts never replaced or redialled a connection.
private struct ConnectionProbe: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        if UserDefaults.standard.bool(forKey: "connectionProbe") {
            Text(value)
                .font(.system(size: 1))
                .opacity(0.02)
                .frame(width: 2, height: 2)
                .accessibilityElement()
                .accessibilityLabel("connections")
                .accessibilityValue(value)
                .accessibilityIdentifier("connection-probe")
        }
    }

    private var value: String {
        model.groups.groups.filter { !$0.isLocal }.map { group in
            let connection = model.app.hosts.connection(group.id)
            let identity = connection.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "none"
            let dials = (connection as? DaemonConnection)?.dials ?? 0
            return "\(group.name)=\(identity)/\(dials)"
        }
        .joined(separator: " ")
    }
}

// MARK: - iPhone

/// iPhone (compact width): one pane full screen under a slim bar on the terminal background whose
struct CompactTerminalView: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !model.isEditorFullScreen { bar }
            TerminalArea(workspace: workspace, compact: true)
        }
        .chromeContent()
        // The bar is the window's base: the terminal's own background under Match Terminal.
        .background(DS.Palette.base, ignoresSafeAreaEdges: .all)
    }

    private var bar: some View {
        HStack(spacing: DS.Space.xs) {
            tabSwitcher
            Spacer()
            if let tab = workspace.session.activeTab, tab.root.panes.count > 1 {
                paneSwitcher(tab)
            }
            Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                .help("Command Palette (⌘K)")
            NewTabButton(workspace: workspace)
        }
        .buttonStyle(.bar)
        .labelStyle(.iconOnly)
        .padding(.horizontal, DS.Space.s)
        // A 36 pt bar with a two-line title: grows with Dynamic Type only as far as it fits.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(height: 36)
    }

    private var tabSwitcher: some View {
        let groups = model.groups.groups
        let total = model.groups.tabs.count
        return Menu {
            if !model.composites.tabs.isEmpty {
                Section("This Window") {
                    ForEach(model.composites.ordered) { mixed in
                        Button {
                            model.focus(WindowModel.mixedRef(mixed.id))
                        } label: {
                            let title = model.title(ofMixedTab: mixed)
                            if model.currentTab == WindowModel.mixedRef(mixed.id) {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Label(title, systemImage: mixed.isEditorOnly ? "chevron.left.forwardslash.chevron.right" : "rectangle.split.2x1")
                            }
                        }
                    }
                }
            }
            // One section per host, its status in the header: every tab on every host is a tap away.
            ForEach(groups) { group in
                Section {
                    ForEach(group.tabs) { tab in
                        let ref = group.ref(tab.id)
                        Button {
                            model.focus(ref)
                        } label: {
                            let title = model.workspace(ofGroup: group.id)?.title(of: tab) ?? tab.title ?? "Shell"
                            if model.currentTab == ref {
                                Label(title, systemImage: "checkmark")
                            } else if let state = tab.root.panes.compactMap({ model.agentState(ofPane: $0, onGroup: group.id) }).min(by: { $0.urgency < $1.urgency }),
                                      state != .idle, state != .unknown
                            {
                                Label(title, systemImage: state == .blocked ? "questionmark.circle.fill" : state == .error ? "xmark.circle.fill" : state == .done ? "checkmark.circle.fill" : "circle.dotted")
                            } else {
                                // The program's mark in the menu's icon column (§3.4: the state
                                // glyph above replaces it while an agent has something to say).
                                let program = model.programIdentity(of: tab, onGroup: group.id)
                                Label { Text(title) } icon: { program.image }
                                    .accessibilityLabel("\(title), \(program.displayName)")
                            }
                        }
                    }
                    if group.isLocal || group.isReady {
                        Button("New Terminal on \(group.name)", systemImage: "plus") { model.newTab(onGroup: group.id) }
                    }
                } header: {
                    Text(group.name)
                }
            }
            if let tab = workspace.session.activeTab {
                Section {
                    TabMenu(tab: tab, workspace: workspace)
                }
            }
        } label: {
            HStack(spacing: DS.Space.row) {
                if let tab = workspace.session.activeTab {
                    ProgramMark(model.programIdentity(of: tab, onGroup: workspace.groupId))
                        .foregroundStyle(.primary)
                }
                // Status UX §3.2 iPhone bar: the tab's title, the host's name as a second line,
                // a state glyph after it only when the host is not live. No dot.
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.activeMixed.map(model.title(ofMixedTab:)) ?? workspace.session.activeTab.map(workspace.title(of:)) ?? (workspace.canOpenTabs ? "No Tabs" : Brand.name))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: DS.Space.xs) {
                        Text(model.hostName)
                            .font(.caption2)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                        if !model.connection.isLive {
                            ConnectionGlyph(model.connection)
                                .font(.caption2)
                        }
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DS.Palette.textSecondary)
                if total > 1 {
                    Text("\(total)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.horizontal, DS.Space.badgeH - 2)
                        .background(DS.Palette.selectedFill, in: .capsule)
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(minHeight: 30)
            .contentShape(.rect)
        }
        .accessibilityIdentifier("tab-switcher")
    }

    private func paneSwitcher(_ tab: Tab) -> some View {
        Menu {
            Picker("Pane", selection: Binding(get: { tab.focused }, set: { workspace.apply(.focus($0)) })) {
                ForEach(Array(tab.root.panes.enumerated()), id: \.element) { index, pane in
                    let program = model.programIdentity(ofPane: pane, onGroup: workspace.groupId)
                    Label { Text(program.isShell ? "Pane \(index + 1)" : program.displayName) } icon: { program.image }
                        .tag(pane)
                }
            }
        } label: {
            Label("Panes", systemImage: "rectangle.split.2x1")
        }
        .menuIndicator(.hidden)
    }
}

// MARK: - Shared

/// Shows or hides the sidebar (⌘B). Hidden, the tabs move to the strip on top; its context menu
/// turns that strip off for a terminal that fills the window.
struct SidebarToggle: View {
    @Environment(WindowModel.self) private var model
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true

    var body: some View {
        Button(model.isSidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading") {
            WorkspaceAction.toggleSidebar.perform(window: model)
        }
        .help(model.isSidebarShown ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)")
        .tint(.primary)
        .contextMenu {
            Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
        }
        .accessibilityIdentifier("toggle-sidebar")
    }
}

/// Rename / Open in New Window / Close for a tab, shared by the strip and the compact switcher.
struct TabMenu: View {
    let tab: Tab
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        Button("Rename…", systemImage: "pencil") { workspace.renamingTab = tab.id }
        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
            model.openInNewWindow(TabRef(hostId: workspace.hostId ?? HostGroups.localId, tab: tab.id))
        }
        Button("Close Tab", systemImage: "xmark", role: .destructive) { workspace.apply(.closeTab(tab.id)) }
    }
}
