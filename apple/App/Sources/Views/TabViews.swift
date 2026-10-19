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
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        let groups = model.groups.groups
        let numbers = Dictionary(uniqueKeysWithValues: model.groups.tabs.enumerated().map { ($1, $0 + 1) })
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 1) {
                    destinationRow(.inbox, title: "Inbox", systemImage: "tray") {
                        CountBadge(model.needsYouCount)
                    }
                    destinationRow(.hosts, title: "Hosts", systemImage: "server.rack") {
                        Text("\(model.hosts.hosts.count)").font(DS.Font.meta).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, DS.Space.s)

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
        .background(theme.sidebarBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        .overlay(alignment: .bottomLeading) { ConnectionProbe() }
    }

    private func destinationRow(_ destination: Destination, title: String, systemImage: String, @ViewBuilder trailing: () -> some View) -> some View {
        let selected = model.destination == destination
        return Button {
            withAnimation(DS.Motion.snappy) { model.destination = destination }
        } label: {
            ListRow(Text(title)) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? .primary : .secondary)
            } trailing: {
                trailing()
            }
            .fontWeight(selected ? .medium : .regular)
            .sidebarRow(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(title.lowercased())")
    }
}

extension View {
    /// (radius 10) inset 8 pt from the column edges. Hover fills on Mac and iPad pointer.
    func sidebarRow(selected: Bool) -> some View {
        modifier(SidebarRowStyle(selected: selected))
    }

    /// A section title in the sidebar, aligned with the rows' text.
    func sidebarHeader() -> some View {
        padding(.horizontal, DS.Space.l + DS.Space.xs)
            .padding(.top, DS.Space.xl)
            .padding(.bottom, DS.Space.xs + 2)
    }
}

private struct SidebarRowStyle: ViewModifier {
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s - 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.pane)
                    .fill(selected ? DS.Palette.selectedFill : hovered ? DS.Palette.hoverFill : .clear))
            .padding(.horizontal, DS.Space.s)
            .onHover { hovered = $0 }
    }
}

struct SelectionFill: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.pane)
            .fill(isSelected ? DS.Palette.selectedFill : .clear)
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
            if !collapsed {
                VStack(spacing: 1) {
                    ForEach(group.tabs) { tab in
                        let ref = group.ref(tab.id)
                        TabRow(tab: tab, ref: ref, number: numbers[ref] ?? 0, group: group)
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

    var body: some View {
        let state = group.connectionState
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.xs + 2) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                ConnectionDot(state)
                Text(group.name)
                    .font(DS.Font.section)
                    .foregroundStyle(group.id == model.currentGroupId && model.destination == .terminal ? .primary : .secondary)
                    .lineLimit(1)
                if group.kind == .ssh {
                    // Plain SSH: tabs do not outlive the connection (no daemon to keep them).
                    Text("SSH")
                        .font(DS.Font.badge)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(.tertiary, lineWidth: 0.5))
                        .help("Plain SSH: tabs end with the connection. Install the helper to keep them.")
                }
                Spacer(minLength: DS.Space.xs)
                if collapsed, !group.tabs.isEmpty {
                    Text("\(group.tabs.count)")
                        .font(DS.Font.meta)
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                }
                Button("New Tab on \(group.name)", systemImage: "plus") { model.newTab(onGroup: group.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bar)
                    .font(.callout)
                    .opacity(showsPlus ? 1 : 0)
                    .help("New Tab on \(group.name)")
                    .accessibilityIdentifier("new-tab-\(group.name)")
            }
            if !state.isLive {
                Text(statusWords)
                    .font(.footnote)
                    .foregroundStyle(state.color)
                    .lineLimit(2)
                    .padding(.leading, 10 + 10 + 2 * (DS.Space.xs + 2))
                    .transition(.opacity)
            }
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.s + 2)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.xs + 2)
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

    private var showsPlus: Bool {
        #if os(macOS)
        hovered && (group.isLocal || group.isReady)
        #else
        group.isLocal || group.isReady
        #endif
    }

    /// could not open.
    private var statusWords: String {
        if let failure = group.failure { return failure }
        switch group.status {
        case .reconnecting(let attempt, _): return attempt > 1 ? "Reconnecting · attempt \(attempt)" : "Reconnecting…"
        case .idle: return "Not connected"
        default: return group.status.summary
        }
    }
}

/// A group's context menu: New Tab, collapse, retry, and closing the host in this window.
private struct GroupMenu: View {
    let group: HostGroup
    let collapsed: Bool
    @Environment(WindowModel.self) private var model

    var body: some View {
        if group.isLocal || group.isReady {
            Button("New Tab", systemImage: "plus") { model.newTab(onGroup: group.id) }
        }
        Button(collapsed ? "Expand" : "Collapse", systemImage: collapsed ? "chevron.down" : "chevron.right") {
            withAnimation(DS.Motion.snappy) { model.groups.toggleCollapsed(group.id) }
        }
        if !group.isLocal {
            if !group.status.isLive {
                Button("Retry Now", systemImage: "arrow.clockwise") { model.hosts.retry(group.id) }
            }
            Divider()
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
            HStack(spacing: DS.Space.s + 2) {
                Image(systemName: group.isReady || group.isLocal ? "plus" : group.failure != nil ? "arrow.clockwise" : "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text(group.isReady || group.isLocal ? "New Tab" : group.failure != nil ? "Retry" : "Waiting for the host…")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(.secondary)
            }
            .sidebarRow(selected: false)
        }
        .buttonStyle(.plain)
    }
}

/// When nothing is open (iPhone and iPad before the first host): one row naming the next step.
private struct NoHostsRow: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        Button { model.addHost() } label: {
            ListRow(Text("Add Host…")) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
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

    var body: some View {
        let workspace = model.workspace(ofGroup: group.id)
        let isActive = model.destination == .terminal && model.currentTab == ref
        let states = tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
        let state = states.min { $0.urgency < $1.urgency }
        let title = workspace?.title(of: tab) ?? tab.title ?? "Shell"
        let context = workspace?.context(of: tab)

        Button {
            withAnimation(DS.Motion.snappy) { model.focus(ref) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s + 2) {
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isActive ? .secondary : .tertiary)
                    .frame(width: 16, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Space.xs + 2) {
                        Text(title)
                            .font(isActive ? DS.Font.rowTitleEmphasis : DS.Font.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let state {
                            StatusIndicator(state, size: 10)
                        }
                        if tab.zoomed != nil {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let context {
                        Text(context)
                            .font(DS.Font.literalSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                #if os(macOS)
                // Shortcut hints only where a keyboard is certain (iPad shows them on ⌘-hold).
                if let shortcut = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(shortcut)")
                        .font(DS.Font.meta)
                        .foregroundStyle(.tertiary)
                }
                #endif
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
            Button("Close Tab", systemImage: "xmark", role: .destructive) { workspace?.apply(.closeTab(tab.id)) }
        }
        .draggable(ref.description)
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
        .accessibilityLabel("\(title), \(group.name)")
        .accessibilityValue(context ?? "")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tab-row-\(number)")
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
            VStack(spacing: 1) {
                ForEach(rows) { row in
                    Button {
                        model.focus(pane: row.pane, onGroup: group.id)
                    } label: {
                        HStack(spacing: DS.Space.s + 2) {
                            StatusIndicator(row.state, size: 12)
                                .frame(width: 16)
                            Text(model.agentProgram(ofPane: row.pane, onGroup: group.id)
                                ?? model.workspace(ofGroup: group.id)?.programName(of: row.pane) ?? "agent")
                                .font(DS.Font.rowSubtitle)
                                .lineLimit(1)
                            Text("\(row.number)")
                                .font(DS.Font.meta)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: DS.Space.xs)
                            Text(row.state.title.lowercased())
                                .font(DS.Font.meta)
                                .foregroundStyle(row.state.color)
                        }
                        .sidebarRow(selected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("agent-\(group.name)-\(row.pane.rawValue)")
                }
            }
            .padding(.top, DS.Space.xs)
        }
    }
}

/// Connection summary and Settings, pinned under the list.
private struct SidebarFooter: View {
    @Environment(WindowModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ConnectionDot(footerState)
            Text(footerText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("connection-status")
            Spacer()
            Button("Settings", systemImage: "gearshape") {
                #if os(macOS)
                openSettings()
                #else
                model.sheet = .settings
                #endif
            }
            .buttonStyle(.bar)
            .accessibilityIdentifier("open-settings")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }

    private var hosts: [HostGroup] { model.groups.groups.filter { !$0.isLocal } }

    /// The window's host when it is down, else every host at a glance.
    private var footerState: ConnectionState {
        if !model.connection.isLive { return model.connection }
        return hosts.first { !$0.status.isLive }?.connectionState ?? model.connection
    }

    /// "studio · Reconnecting" for the host on screen; else "3 hosts connected", or the one host
    /// that is not ("hetzner · Reconnecting"); "Local" with no hosts open.
    private var footerText: String {
        if model.connectionOverride != nil || !model.connection.isLive {
            return "\(model.hostName) · \(model.connection.title)"
        }
        let down = hosts.filter { !$0.status.isLive }
        if let first = down.first { return down.count == 1 ? "\(first.name) · \(first.connectionState.title)" : "\(down.count) hosts not connected" }
        if hosts.count > 1 { return "\(hosts.count) hosts connected" }
        if model.isRemote, let status = model.workspace?.host?.status.summary { return status }
        return LaunchOptions.hasLocalShell ? "Local" : "No host connected"
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
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.xs) {
                tabSwitcher
                Spacer()
                if let tab = workspace.session.activeTab, tab.root.panes.count > 1 {
                    paneSwitcher(tab)
                }
                Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                NewTabButton(workspace: workspace)
            }
            .buttonStyle(.bar)
            .labelStyle(.iconOnly)
            .padding(.horizontal, DS.Space.s)
            .frame(height: 36)
            ActiveTabView(workspace: workspace, compact: true)
                .id(ObjectIdentifier(workspace))
        }
        .background(theme.background.ignoresSafeArea())
        // The bar sits on the terminal, so it takes the terminal's light/dark, not the system's.
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
    }

    private var tabSwitcher: some View {
        let groups = model.groups.groups
        let total = model.groups.tabs.count
        return Menu {
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
                            } else if let state = tab.root.panes.compactMap({ model.agentState(ofPane: $0, onGroup: group.id) }).min(by: { $0.urgency < $1.urgency }) {
                                Label(title, systemImage: state.needsYou ? "exclamationmark.circle" : state == .working ? "circle.dotted" : "circle")
                            } else {
                                Text(title)
                            }
                        }
                    }
                    if group.isLocal || group.isReady {
                        Button("New Tab on \(group.name)", systemImage: "plus") { model.newTab(onGroup: group.id) }
                    }
                } header: {
                    Text(group.isLocal || group.status.isLive ? group.name : "\(group.name) · \(group.connectionState.title)")
                }
            }
            if let tab = workspace.session.activeTab {
                Section {
                    TabMenu(tab: tab, workspace: workspace)
                }
            }
        } label: {
            HStack(spacing: DS.Space.xs + 2) {
                ConnectionDot(model.connection)
                if groups.count > 1 {
                    Text(model.hostName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(workspace.session.activeTab.map(workspace.title(of:)) ?? (workspace.canOpenTabs ? "No Tabs" : Brand.name))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if total > 1 {
                    Text("\(total)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .background(.fill.tertiary, in: .capsule)
                }
            }
            .padding(.horizontal, DS.Space.xs)
            .frame(height: 30)
            .contentShape(.rect)
        }
        .accessibilityIdentifier("tab-switcher")
    }

    private func paneSwitcher(_ tab: Tab) -> some View {
        Menu {
            Picker("Pane", selection: Binding(get: { tab.focused }, set: { workspace.apply(.focus($0)) })) {
                ForEach(Array(tab.root.panes.enumerated()), id: \.element) { index, pane in
                    Label(model.paneStatus.program(of: pane.description) ?? "Pane \(index + 1)",
                          systemImage: model.paneStatus.state(of: pane.description) == nil ? "terminal" : "sparkle")
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

struct TabStyleToggle: View {
    @Binding var style: TabStyle

    var body: some View {
        Button(
            style == .sidebar ? "Tabs on Top" : "Tabs in Sidebar",
            systemImage: style == .sidebar ? "rectangle.topthird.inset.filled" : "sidebar.left"
        ) {
            withAnimation(DS.Motion.panel) { style = style == .sidebar ? .bar : .sidebar }
        }
        .help("Switch between vertical and horizontal tabs")
    }
}

/// Rename / Close for a tab, shared by the strip and the compact switcher.
struct TabMenu: View {
    let tab: Tab
    let workspace: Workspace

    var body: some View {
        Button("Rename…", systemImage: "pencil") { workspace.renamingTab = tab.id }
        Button("Close Tab", systemImage: "xmark", role: .destructive) { workspace.apply(.closeTab(tab.id)) }
    }
}
