import DesignSystem
import PaneLayout
import SwiftUI

// MARK: - Sidebar (vertical tabs)

/// then this session's tabs with their panes and agent status, and a footer with the connection
/// and settings. Selection is a quiet fill, not the accent: color stays reserved for state.
struct WorkspaceSidebar: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                destinationRow(.inbox, title: "Inbox", systemImage: "tray") {
                    CountBadge(model.needsYouCount)
                }
                destinationRow(.hosts, title: "Hosts", systemImage: "server.rack") {
                    Text("\(model.hosts.hosts.count)").font(DS.Font.meta).foregroundStyle(.tertiary)
                }
            }

            Section {
                ForEach(Array(workspace.session.tabs.enumerated()), id: \.element.id) { index, tab in
                    TabRow(tab: tab, index: index, workspace: workspace)
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    // `destination` is an insertion point in the original order.
                    workspace.apply(.moveTab(workspace.session.tabs[from].id, to: destination > from ? destination - 1 : destination))
                }
            } header: {
                SessionHeader()
            }

            AgentsSection(workspace: workspace)
        }
        .listStyle(.sidebar)
        #if os(iOS)
        // An opaque sidebar: the floating glass one samples the dark terminal beside it and turns
        // a muddy grey in light mode. Mail and Files use the same grouped background.
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
        #endif
        .navigationTitle(Brand.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Tab", systemImage: "plus") { workspace.apply(.newTab) }
                    .help("New Tab (⌘T)")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
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
        }
        .buttonStyle(.plain)
        .listRowBackground(SelectionFill(isSelected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(title.lowercased())")
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

/// "This iPad" / "This Mac" with the connection dot; the host name once the daemon is wired.
private struct SessionHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Space.xs + 2) {
            SectionTitle(deviceName)
            Spacer()
            ConnectionDot(model.connection)
        }
    }

    private var deviceName: String {
        #if os(macOS)
        "This Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #endif
    }
}

/// and on the Mac its ⌘N on the right.
private struct TabRow: View {
    let tab: Tab
    let index: Int
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    var body: some View {
        let isActive = model.destination == .terminal && tab.id == workspace.session.activeTabId
        let states = tab.root.panes.compactMap { model.paneStatus.state(of: $0.description) }
        let state = states.min { $0.urgency < $1.urgency }
        let title = workspace.title(of: tab)

        Button {
            withAnimation(DS.Motion.snappy) {
                model.destination = .terminal
                workspace.selectTab(tab.id)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s + 2) {
                Text("\(index + 1)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isActive ? .secondary : .tertiary)
                    .frame(width: 16, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Space.xs + 2) {
                        Text(title)
                            .font(isActive ? DS.Font.rowTitleEmphasis : DS.Font.rowTitle)
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
                    if let subtitle = subtitle(title: title) {
                        Text(subtitle)
                            .font(DS.Font.literalSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: DS.Space.xs)
                #if os(macOS)
                // Shortcut hints only where a keyboard is certain (iPad shows them on ⌘-hold).
                if index < 8 {
                    Text("⌘\(index + 1)")
                        .font(DS.Font.meta)
                        .foregroundStyle(.tertiary)
                }
                #endif
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(SelectionFill(isSelected: isActive))
        .contextMenu { TabMenu(tab: tab, workspace: workspace) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("sidebar-\(tab.id)")
    }

    /// The directory when the title is something else, else the pane count of a split.
    private func subtitle(title: String) -> String? {
        if let directory = workspace.directory(of: tab), directory != title { return directory }
        let count = tab.root.panes.count
        return count > 1 ? "\(count) panes" : nil
    }
}

/// tab number, and the state word right-aligned in its color.
private struct AgentsSection: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model

    private struct Row: Identifiable {
        var index: Int
        var pane: PaneId
        var state: AgentState
        var id: PaneId { pane }
    }

    var body: some View {
        let rows: [Row] = workspace.session.tabs.enumerated().flatMap { index, tab in
            tab.root.panes.compactMap { pane in
                model.paneStatus.state(of: pane.description).map { Row(index: index, pane: pane, state: $0) }
            }
        }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    Button {
                        model.destination = .terminal
                        workspace.apply(.focus(row.pane))
                    } label: {
                        HStack(spacing: DS.Space.s + 2) {
                            StatusIndicator(row.state, size: 12)
                                .frame(width: 16)
                            Text(model.paneStatus.program(of: row.pane.description) ?? workspace.programName(of: row.pane))
                                .font(DS.Font.rowTitle)
                                .lineLimit(1)
                            Text("\(row.index + 1)")
                                .font(DS.Font.meta)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: DS.Space.xs)
                            Text(row.state.title.lowercased())
                                .font(DS.Font.meta)
                                .foregroundStyle(row.state.color)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SectionTitle("Agents")
            }
        }
    }
}

/// Connection summary and Settings, pinned under the list.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ConnectionDot(model.connection)
            Text(model.connection == .connected ? "Local" : model.connection.title)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
}

// MARK: - iPhone

/// iPhone (compact width): one pane full screen under a slim bar on the terminal background whose
struct CompactTerminalView: View {
    let workspace: Workspace
    @Environment(AppModel.self) private var model
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
                Button("New Tab", systemImage: "plus") { workspace.apply(.newTab) }
            }
            .buttonStyle(.bar)
            .labelStyle(.iconOnly)
            .padding(.horizontal, DS.Space.s)
            .frame(height: 36)
            ActiveTabView(workspace: workspace, compact: true)
        }
        .background(theme.background.ignoresSafeArea())
        // The bar sits on the terminal, so it takes the terminal's light/dark, not the system's.
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
    }

    private var tabSwitcher: some View {
        Menu {
            Picker("Tab", selection: Binding(
                get: { workspace.session.activeTabId },
                set: { id in if let id { workspace.selectTab(id) } })
            ) {
                ForEach(workspace.session.tabs) { tab in
                    Text(workspace.title(of: tab)).tag(Optional(tab.id))
                }
            }
            if let tab = workspace.session.activeTab {
                Divider()
                TabMenu(tab: tab, workspace: workspace)
            }
        } label: {
            HStack(spacing: DS.Space.xs + 2) {
                ConnectionDot(model.connection)
                Text(workspace.session.activeTab.map(workspace.title(of:)) ?? "No Tabs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                if workspace.session.tabs.count > 1 {
                    Text("\(workspace.session.tabs.count)")
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

/// Rename / Close for a tab, shared by the sidebar, the strip and the compact switcher.
struct TabMenu: View {
    let tab: Tab
    let workspace: Workspace

    var body: some View {
        Button("Rename…", systemImage: "pencil") { workspace.renamingTab = tab.id }
        Button("Close Tab", systemImage: "xmark", role: .destructive) { workspace.apply(.closeTab(tab.id)) }
    }
}
