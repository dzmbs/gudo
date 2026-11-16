import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

// MARK: - Sidebar (vertical tabs)

#if DEBUG
/// Counts body evaluations of the sidebar's and the tab bar's views while a test watches.
@MainActor
enum ChromeRenders {
    static var counts: [String: Int]?

    static func note(_ view: @autoclosure () -> String) {
        guard counts != nil else { return }
        counts?[view(), default: 0] += 1
    }
}
#endif

/// The sidebar: Inbox and Hosts on top, then one group per host the window shows. Every host is
/// live at once, and tab numbers (⌘1…⌘9) run across hosts.
///
/// Native list reuse with the system's row fills hidden, so the terminal palette owns the chrome.
struct WorkspaceSidebar: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.sidebarListStyle) private var listStyle
    /// Inbox and Hosts on top; the tab overview leaves them to the iPhone's tab bar.
    var showsDestinations = true
    @State private var swipe = RowSwipeState()
    @State private var geometry = SidebarGeometry()
    @State private var scroll = SidebarScroll()

    var body: some View {
        #if DEBUG
        let _ = ChromeRenders.note("sidebar")
        #endif
        ScrollViewReader { proxy in
            list.background(ActiveRowReveal(geometry: geometry, scroll: scroll, proxy: proxy))
        }
    }

    private var list: some View {
        List {
            Group {
                if showsDestinations {
                    VStack(spacing: 0) {
                        destinationRow(.inbox) {
                            CountBadge(model.needsYouCount)
                        }
                        destinationRow(.hosts) {
                            Text("\(model.hosts.hostCount)").font(DS.Font.meta).foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    .padding(.top, DS.Space.s)
                }

                SidebarTabList(geometry: geometry)

                if model.groups.groups.isEmpty {
                    NoHostsRow()
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .animation(DS.Motion.standard, value: model.groups.collapsed)
            .animation(DS.Motion.standard, value: model.groups.collapsedProjects)
        }
        .listStyle(.plain)
        .contentMargins(.all, 0, for: .scrollContent)
        .coordinateSpace(name: "sidebar-list")
        // Written here, read only by the pinned header, so scrolling never rebuilds the list.
        .onScrollGeometryChange(for: [CGFloat].self) {
            [$0.contentOffset.y, $0.contentInsets.top, $0.containerSize.height - $0.contentInsets.bottom]
        } action: { _, values in
            scroll.offset = values[0]
            scroll.top = values[1]
            scroll.bottom = values[2]
        }
        .overlay(alignment: .top) {
            if listStyle == .plain {
                StickyProjectHeader(geometry: geometry, scroll: scroll)
            }
        }
        .onDrop(of: [.text], delegate: SidebarDropDelegate(model: model, drag: model.sidebarDrag, geometry: geometry))
        .environment(model.sidebarDrag)
        #if os(iOS)
        .listRowSpacing(0)
        .listSectionSpacing(0)
        #endif
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        #if os(macOS)
        // Rows keep their own menus.
        .contextMenu {
            Button(WorkspaceAction.newProject.title, systemImage: "folder.badge.plus") {
                withAnimation(DS.Motion.standard) { model.newEmptyProject() }
            }
        }
        #endif
        .scrollIndicators(.never)
        .environment(swipe)
        .onScrollPhaseChange { _, phase in if phase != .idle { swipe.open = nil } }
        // Dense rows in a fixed column; the column grows with them (`SidebarWidth`). The
        // iPhone's full-width list takes every size.
        .dynamicTypeSize(...(listStyle == .grouped ? DynamicTypeSize.accessibility5 : .accessibility1))
        .chromeContent()
        .chromeBackground(listStyle == .grouped ? DS.Palette.groupedPage : DS.Palette.sidebar)
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelectingTabs || model.tabSelection.isMultiple {
                TabSelectionBar()
                    .motionTransition(.panel(from: .bottom))
            }
        }
        .animation(DS.Motion.standard, value: model.isSelectingTabs || model.tabSelection.isMultiple)
        .overlay(alignment: .bottomLeading) { ConnectionProbe() }
    }

    private func destinationRow(_ destination: Destination, @ViewBuilder trailing: () -> some View) -> some View {
        let selected = model.destination == destination
        return Button {
            withAnimation(DS.Motion.standard) { model.destination = destination }
        } label: {
            // The tab rows' own measure: the glyph in their program slot, the title where theirs start.
            HStack(spacing: DS.Space.gap10) {
                Image(systemName: destination.systemImage)
                    .font(SidebarFont.title)
                    .foregroundStyle(selected ? DS.Palette.text : DS.Palette.textSecondary)
                    .frame(width: SidebarFont.icon, height: SidebarFont.icon)
                Text(destination.title)
                    .font(SidebarFont.title)
                    .foregroundStyle(SidebarRowInk.title(selected: selected))
                    .lineLimit(1)
                Spacer(minLength: DS.Space.xs)
                trailing()
                    .font(SidebarFont.number)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.leading, DS.Space.xs)
            .accessibilityElement(children: .combine)
            .sidebarRow(selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(destination.rawValue)")
    }
}

/// Keeps the active tab's row in view; a view of its own so a tab change re-renders only this.
private struct ActiveRowReveal: View {
    let geometry: SidebarGeometry
    let scroll: SidebarScroll
    let proxy: ScrollViewProxy
    @Environment(WindowModel.self) private var model

    var body: some View {
        Color.clear
            .onChange(of: model.destination == .terminal ? model.shownTab : nil) { _, ref in
                guard let ref else { return }
                // Once the list has laid out the row a new tab adds.
                Task { @MainActor in geometry.reveal(ref, scroll: scroll, proxy: proxy) }
            }
    }
}

/// The sidebar's width: the user's (dragged) width, widened as Dynamic Type grows so its
/// rows keep their titles and state words on one line.
enum SidebarWidth {
    static let range: ClosedRange<Double> = 200...360
    static let standard = 264.0

    static func effective(_ stored: Double, for size: DynamicTypeSize) -> Double {
        let extra: Double = switch size {
        case ...DynamicTypeSize.large: 0
        case .xLarge: 12
        case .xxLarge: 24
        case .xxxLarge: 44
        default: 72
        }
        return min(max(stored, range.lowerBound) + extra + SidebarSize.shared.metrics.widthExtra, range.upperBound + 72)
    }
}

/// How the tab list draws: the sidebar's dense rows, or the iPhone's grouped cards per project.
enum SidebarListStyle {
    case plain, grouped
}

/// Where a row sits among its section's rows, for the corners of a grouped card.
struct GroupedRowPosition: Equatable {
    var isFirst: Bool
    var isLast: Bool
    static let alone = GroupedRowPosition(isFirst: true, isLast: true)
}

extension EnvironmentValues {
    @Entry var sidebarListStyle = SidebarListStyle.plain
    @Entry var groupedRowPosition = GroupedRowPosition.alone
}

extension View {
    /// A sidebar row: a full-width hit area with a soft selection and hover fill.
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
    @Environment(\.sidebarListStyle) private var listStyle
    @Environment(\.groupedRowPosition) private var position

    func body(content: Content) -> some View {
        switch listStyle {
        case .plain: plain(content)
        case .grouped: grouped(content)
        }
    }

    /// An inset grouped card, as iOS lists draw them: 44 pt at least, rounded at the section's
    /// ends, a hairline between rows that starts at the text.
    private func grouped(_ content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position.isFirst ? DS.Radius.pane : 0, bottomLeadingRadius: position.isLast ? DS.Radius.pane : 0,
            bottomTrailingRadius: position.isLast ? DS.Radius.pane : 0, topTrailingRadius: position.isFirst ? DS.Radius.pane : 0,
            style: .continuous)
        return content
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: .infinity, minHeight: DS.Size.touchTarget, alignment: .leading)
            .contentShape(.rect)
            .background(selected ? AnyShapeStyle(DS.Palette.selectedFill) : AnyShapeStyle(DS.Palette.groupedRow), in: shape)
            .overlay(alignment: .bottom) {
                if !position.isLast {
                    Rectangle()
                        .fill(DS.Palette.separator)
                        .frame(height: 0.5)
                        .padding(.leading, DS.Space.l + SidebarFont.icon + DS.Space.gap10)
                }
            }
            .padding(.horizontal, DS.Space.l)
    }

    private func plain(_ content: Content) -> some View {
        content
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .controlFill(ControlState(isHovered: hovered, isSelected: selected))
            #if os(iOS)
            .contentShape(.hoverEffect, RoundedRectangle.rounded(DS.Radius.control))
            .hoverEffect(.highlight)
            #endif
            .padding(.horizontal, DS.Space.s)
            .onHover { hovered = $0 }
    }
}

/// The sidebar's text at Apple's sidebar sizes, through `DS.Font.sidebar`: the size chosen in
/// Settings (`sidebar-text-size`), or by default the Mac's own sidebar size from System Settings
/// (11, 13 or 15 pt rows, as the system's source lists draw them) and the body and subheadline
/// text styles on touch, so Dynamic Type applies. Weight never changes with selection; the fill
/// shows it.
@MainActor
enum SidebarFont {
    static var title: Font { SidebarSize.shared.metrics.title }
    static var subtitle: Font { SidebarSize.shared.metrics.subtitle }
    static var section: Font { SidebarSize.shared.metrics.section }
    static var project: Font { SidebarSize.shared.metrics.project }
    static var number: Font { SidebarSize.shared.metrics.number }
    static var icon: CGFloat { SidebarSize.shared.metrics.icon }
    static var projectMark: CGFloat { SidebarSize.shared.metrics.projectMark }
}

/// The sidebar's text size, kept current while the app runs: the Settings choice, and on the Mac
/// System Settings › Appearance › Sidebar icon size behind its System choice.
@MainActor
@Observable
final class SidebarSize {
    static let shared = SidebarSize()

    private(set) var size = SidebarSize.storedSize

    var metrics: DS.Font.Sidebar { DS.Font.sidebar(size) }

    private init() {
        #if os(macOS)
        let names = [UserDefaults.didChangeNotification, NSApplication.didBecomeActiveNotification]
        #else
        let names = [UserDefaults.didChangeNotification]
        #endif
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SidebarSize.shared.refresh() }
            }
        }
    }

    private func refresh() {
        let stored = Self.storedSize
        if stored != size { size = stored }
    }

    private static var storedSize: DS.Font.SidebarSize {
        let preference = UserDefaults.standard.string(forKey: TerminalPreferences.Key.sidebarTextSize)
            .flatMap(TerminalPreferences.SidebarTextSize.init(rawValue:)) ?? TerminalPreferences.Default.sidebarTextSize
        #if os(macOS)
        // `NSTableViewDefaultSizeMode`: 1 small, 2 medium, 3 large; 0 when never set.
        let systemMode = UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode")
        #else
        let systemMode = DS.Font.SidebarSize.medium.rawValue
        #endif
        return DS.Font.SidebarSize(preference, systemMode: systemMode)
    }
}

/// A sidebar row's title: the full ink on the selected row, so selection reads in the words as
/// well as the fill; the main text level elsewhere.
enum SidebarRowInk {
    static func title(selected: Bool) -> ChromeStyle { selected ? DS.Palette.ink : DS.Palette.text }
}

/// The highlight behind a selected sidebar row.
struct SelectionFill: View {
    let isSelected: Bool

    var body: some View {
        RoundedRectangle.rounded(DS.Radius.control)
            .fill(DS.Palette.selectedFill.opacity(isSelected ? 1 : 0))
            .padding(.horizontal, DS.Space.s)
    }
}

extension HostGroup {
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

/// One host's header in the tab list: its name and state, then its agents' plan usage.
struct HostGroupHeaderItem: View {
    let group: HostGroup
    @Environment(WindowModel.self) private var model

    var body: some View {
        let collapsed = model.groups.collapsed.contains(group.id)
        VStack(alignment: .leading, spacing: 0) {
            HostGroupHeader(group: group, collapsed: collapsed)
            if group.kind == .daemon || LaunchOptions.fakeUsage {
                HostUsageMeters(hostId: group.id, hostName: group.name, onlyNearingLimits: true)
                    .padding(.leading, DS.Space.l + 16 + DS.Space.s)
                    .padding(.trailing, DS.Space.gap10)
                    .padding(.bottom, DS.Space.xs)
            }
        }
    }
}

private struct HostGroupHeader: View {
    let group: HostGroup
    let collapsed: Bool
    @Environment(WindowModel.self) private var model
    @State private var hovered = false

    var body: some View {
        #if DEBUG
        let _ = ChromeRenders.note("host-header")
        #endif
        let state = group.connectionState
        let live = group.showsAsLive
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.s) {
                ConnectionGlyph(
                    state,
                    healthy: Image(systemName: group.isLocal ? "laptopcomputer" : "server.rack")
                        .foregroundStyle(DS.Palette.textSecondary).opacity(DS.Opacity.mutedGlyph))
                    // The header's own text style, so the glyph grows with Dynamic Type.
                    .font(SidebarFont.section.weight(.regular))
                    .imageScale(.small)
                    .frame(minWidth: 16)
                    .help(group.failure ?? (live ? group.name : state.title))
                Text(group.name)
                    .font(SidebarFont.section)
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
                        .hairlineBorder(RoundedRectangle.rounded(DS.Radius.chip), style: DS.Palette.textTertiary)
                        .help("Plain SSH: tabs end with the connection. Install the helper to keep them.")
                }
                Spacer(minLength: DS.Space.xs)
                // What the collapse hides: the host's loose tabs.
                if collapsed, case let hidden = model.groups.looseTabs(of: group).count, hidden > 0 {
                    Text("\(hidden)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .contentTransition(.numericText())
                }
                HostAgentsBadge(group: group)
                plus
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bar)
                    .font(.callout)
                    // Always there, so a host with no tabs never looks like a dead end.
                    .opacity(canOpen ? (plusEmphasized ? 1 : 0.45) : 0)
                    .disabled(!canOpen)
                    .accessibilityIdentifier("new-tab-\(group.name)")
            }
        }
        .popover(isPresented: Binding(
            get: { model.usageDetailHost == group.id },
            set: { if !$0, model.usageDetailHost == group.id { model.usageDetailHost = nil } })
        ) {
            UsageDetailView(hostName: group.name, report: model.usage.usage(forHost: group.id))
                .chromePopover()
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.gap10)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.xxs)
        .contentShape(.rect)
        .onTapGesture { withAnimation(DS.Motion.standard) { model.groups.toggleCollapsed(group.id) } }
        .onHover { hovered = $0 }
        .animation(DS.Motion.standard, value: state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(state.title)")
        .accessibilityValue(state.title)
        .accessibilityHint(collapsed ? "Shows its tabs" : "Hides its tabs")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("host-group-\(group.name)")
        .accessibilityAction(named: "New Tab") { model.newTab(onGroup: group.id) }
        .rowActions(actions, id: "host-\(group.id)", name: group.name, perform: perform) {
            GroupMenu(group: group, collapsed: collapsed)
        }
    }

    private var actions: RowActions {
        RowActions(.host(isLocal: group.isLocal, isOpen: true, isPinned: model.hosts.isPinned(group.id)))
    }

    private func perform(_ action: RowAction) {
        switch action {
        case .pin, .unpin: model.hosts.togglePin(group.id)
        case .disconnect: model.closeHost(group.id)
        case .removeHost: model.hosts.forget(group.id)
        default: break
        }
    }

    /// New Terminal, and New Agent where the host runs agents (a daemon).
    @ViewBuilder private var plus: some View {
        if group.kind == .daemon {
            Menu {
                NewOnHostItems(group: group)
            } label: {
                Label("New on \(group.name)", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .help("New Terminal or New Agent on \(group.name)")
        } else {
            Button("New Terminal on \(group.name)", systemImage: "plus") { model.newTab(onGroup: group.id) }
                .help("New Terminal on \(group.name)")
        }
    }

    private var canOpen: Bool { group.isLocal || group.isReady }

    /// Full strength on hover on the Mac; always on touch, where there is no hover.
    private var plusEmphasized: Bool {
        #if os(macOS)
        hovered
        #else
        true
        #endif
    }
}

/// The most urgent agent state across a host's panes, opening its agents. A view of its own,
/// so a pane's title or status changing re-renders this glyph, not the host's header.
private struct HostAgentsBadge: View {
    let group: HostGroup
    @Environment(WindowModel.self) private var model
    @State private var showsAgents = false

    var body: some View {
        if let agents = aggregateAgentState {
            HoverPopover(isPresented: $showsAgents) {
                StateMark(agents)
                    .frame(minWidth: 22, minHeight: 22)
                    .contentShape(.rect)
            } content: {
                HostAgentsPopover(group: group) { showsAgents = false }
            }
            .buttonStyle(.plain)
            .help("Agents on \(group.name)")
            .accessibilityIdentifier("host-agents-\(group.name)")
        }
    }

    private var aggregateAgentState: AgentState? {
        let states = group.tabs.flatMap(\.root.panes).compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
        return AgentState.mostUrgent(states.filter { $0 != .idle && $0 != .unknown })
    }
}

/// A host's agents at a glance, one row each; a row focuses its pane.
private struct HostAgentsPopover: View {
    let group: HostGroup
    let onSelect: () -> Void
    @Environment(WindowModel.self) private var model

    var body: some View {
        let workspace = model.workspace(ofGroup: group.id)
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
                            HStack(spacing: DS.Space.s) {
                                SidebarTabIcon(program: program, state: state)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(workspace?.title(of: tab) ?? tab.title ?? program.displayName)
                                        .font(SidebarFont.title)
                                        .lineLimit(1)
                                    Text("\(program.isShell ? "Agent" : program.displayName) · \(state.title.lowercased())")
                                        .font(SidebarFont.subtitle)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: DS.Space.s)
                            }
                            .frame(minWidth: 240)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if group.kind == .daemon || LaunchOptions.fakeUsage {
                HostUsageMeters(hostId: group.id, hostName: group.name)
            }
        }
        .hoverPopoverFrame()
    }
}

/// The slot leading a tab's name in the strip: the program's tile, its agent's quiet state a dot
/// on the tile (what needs you is a pill after the title). Every chip has the slot, so titles
/// line up.
struct TabLeadingMark: View {
    let program: ProgramIdentity
    let state: AgentState?
    /// A browser tab's page icon, shown instead of the program's mark.
    var favicon: Image?
    var isSelected = false

    var body: some View {
        TabTile(program: program, state: state, favicon: favicon, size: ProgramTile.rowSize, isSelected: isSelected)
            .frame(width: ProgramMark.rowSlot, height: ProgramMark.rowSlot)
            // One baseline whatever the slot holds, so the chip's title stays on the same line.
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 3 }
    }

    /// The row's spoken label: name, then the agent's state or the program, then the host.
    static func label(title: String, program: ProgramIdentity, state: AgentState?, host: String?) -> String {
        let shown = state.flatMap { $0 == .idle || $0 == .unknown ? nil : "\(program.displayName), \($0.title)" } ?? program.displayName
        return [title, shown, host].compactMap(\.self).joined(separator: ", ")
    }
}

/// A sidebar row's program tile, its agent's quiet state a dot on the tile's corner (what needs
/// you is a pill after the title), so the state never takes the title's room and every row's
/// title starts at the same place.
struct SidebarTabIcon: View {
    let program: ProgramIdentity
    let state: AgentState?
    var favicon: Image?
    var isSelected = false

    var body: some View {
        TabTile(program: program, state: state, favicon: favicon, size: SidebarFont.icon, isSelected: isSelected)
            .accessibilityHidden(true)
    }
}

/// A tab's tile: its program's mark, or a browser tab's page icon, with the quiet state's dot.
private struct TabTile: View {
    let program: ProgramIdentity
    let state: AgentState?
    let favicon: Image?
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        if let favicon {
            TileArtwork(size: size, isSelected: isSelected) { glyphSize, _ in
                Favicon(image: favicon, size: glyphSize)
            }
            .stateDot(state, tileSize: size)
        } else {
            ProgramTile(program, size: size, isSelected: isSelected, state: state)
        }
    }
}

/// A tab with several panes opens into a list of them from this chevron, before its number.
struct TreeChevron: View {
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DS.Palette.textTertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12, height: SidebarFont.icon)
            // A finger's 44 pt target around the small glyph, without moving the row's layout.
            .contentShape(.rect.inset(by: -(DS.Size.touchTarget - 12) / 2))
            .highPriorityGesture(TapGesture().onEnded { toggle() })
            .accessibilityLabel(isExpanded ? "Hide panes" : "Show panes")
            .accessibilityAddTraits(.isButton)
    }
}

/// Opening a tab into its panes from VoiceOver (the row combines its chevron away), and closing it
/// once it is down to one pane, so a later split does not open it by itself.
private struct PaneTreeActions: ViewModifier {
    let ref: TabRef
    let paneCount: Int
    let opens: Bool
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        let expanded = model.expandedTabs.contains(ref)
        content
            .accessibilityActions {
                if opens, paneCount > 1 {
                    Button(expanded ? "Hide Panes" : "Show Panes") {
                        withAnimation(DS.Motion.standard) { model.expandedTabs.formSymmetricDifference([ref]) }
                    }
                }
            }
            .onChange(of: paneCount) { _, count in
                if count < 2, expanded { model.expandedTabs.remove(ref) }
            }
    }
}

/// One pane of an opened tab: its program and state, named as its tab would be (an agent by its
/// task, a shell by its folder); showing it focuses that pane.
struct PaneTreeRow: View {
    let pane: PaneId
    let group: HostGroup
    let isFocusedPane: Bool
    @Environment(WindowModel.self) private var model

    var body: some View {
        let program = model.programIdentity(ofPane: pane, onGroup: group.id)
        let state = model.agentState(ofPane: pane, onGroup: group.id)
        let workspace = model.workspace(ofGroup: group.id)
        let title = switch program.kind {
        case .agent:
            AgentTabTitle(terminalTitle: workspace?.panes[pane]?.agentTitle, kind: AgentKind(program.id), name: program.displayName).resolved
        case _ where program.isShell:
            workspace?.directory(ofPane: pane) ?? workspace?.panes[pane]?.title.nonEmpty ?? program.displayName
        default: program.displayName
        }
        Button {
            model.focus(pane: pane, onGroup: group.id)
        } label: {
            HStack(spacing: DS.Space.gap10) {
                SidebarTabIcon(program: program, state: state)
                    .scaleEffect(0.82)
                Text(title)
                    .font(SidebarFont.subtitle)
                    .foregroundStyle(isFocusedPane ? DS.Palette.text : DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let state { StatePill(state) }
            }
            // One level in: the pane's icon sits under its tab's title.
            .padding(.leading, SidebarFont.icon + DS.Space.gap10 + DS.Space.xs)
            .sidebarRow(selected: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TabLeadingMark.label(title: title, program: program, state: state, host: nil))
    }
}

/// A tab's ⌘ shortcut at the row's trailing edge, shown only while ⌘ is held.
struct TabShortcut: View {
    let number: Int

    var body: some View {
        Text("⌘\(number)")
            .font(SidebarFont.number)
            .foregroundStyle(DS.Palette.textSecondary)
            .lineLimit(1)
            .fixedSize()
            // A renumbered row swaps its digit in place, never a cross-fade.
            .contentTransition(.identity)
            .accessibilityHidden(true)
    }
}

/// A tab that called for the user out of sight, until it is shown.
struct AttentionDot: View {
    var body: some View {
        Circle()
            .fill(DS.Palette.attentionMark)
            .frame(width: DS.Size.attentionDot, height: DS.Size.attentionDot)
            .accessibilityLabel("Wants attention")
    }
}

/// The one thing at a tab row's trailing edge, the most pressing; the rest wait for the hover
/// or the second line.
enum TabRowAccessory: Hashable {
    case selection(isSelected: Bool)
    case shortcut(Int)
    case pill(AgentState)
    case panes(isExpanded: Bool)
    case attention
    case diff
    case presence
    case none

    /// `shortcut` is the row's ⌘N while ⌘ is held, else nil.
    static func pick(
        isSelecting: Bool, isSelected: Bool, shortcut: Int?, state: AgentState?, paneCount: Int, opensPanes: Bool,
        isExpanded: Bool, isHovered: Bool, needsAttention: Bool, hasDiff: Bool, hasPresence: Bool
    ) -> TabRowAccessory {
        if isSelecting { return .selection(isSelected: isSelected) }
        if let shortcut { return .shortcut(shortcut) }
        if let state, state.statusMark == .pill { return .pill(state) }
        if opensPanes, paneCount > 1, isHovered || isExpanded { return .panes(isExpanded: isExpanded) }
        if needsAttention { return .attention }
        if hasDiff { return .diff }
        if hasPresence { return .presence }
        return .none
    }
}

/// New Terminal on a host, and New Agent where it runs agents (a daemon).
private struct NewOnHostItems: View {
    let group: HostGroup
    @Environment(WindowModel.self) private var model

    var body: some View {
        Button("New Terminal", systemImage: "terminal") { model.newTab(onGroup: group.id) }
            .accessibilityIdentifier("host-new-terminal-\(group.name)")
        if group.kind == .daemon {
            Button(WorkspaceAction.newAgent.title, systemImage: "sparkle") { model.newAgent(onGroup: group.id) }
                .accessibilityIdentifier("host-new-agent-\(group.name)")
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
            NewOnHostItems(group: group)
        }
        Button(collapsed ? "Expand" : "Collapse", systemImage: collapsed ? "chevron.down" : "chevron.right") {
            withAnimation(DS.Motion.standard) { model.groups.toggleCollapsed(group.id) }
        }
        if !group.isLocal {
            if !group.status.isLive {
                Button("Retry Now", systemImage: "arrow.clockwise") { model.hosts.retry(group.id) }
            }
            Divider()
            if WindowRequest.isSupported {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openInNewWindow(host: group.id) }
            }
            if group.kind == .daemon {
                Button("Agent Usage", systemImage: "gauge.with.dots.needle.33percent") { model.usageDetailHost = group.id }
            }
            Button("Show in Hosts", systemImage: "server.rack") { model.destination = .hosts }
        }
    }
}

/// A host with no tabs yet: what is happening, in words.
struct GroupPlaceholder: View {
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

/// One tab: its number across all hosts, name and status glyph, and its context underneath.
/// Dragged by the list (`SidebarTabList`).
struct TabRow: View {
    let tab: Tab
    let ref: TabRef
    let number: Int
    let group: HostGroup
    var showsHost = false
    @Environment(WindowModel.self) private var model

    @Environment(\.sidebarListStyle) private var listStyle
    /// The command that has run long enough to name; a quick one never changes the row's height.
    @State private var longRunning: UInt64?
    @State private var hovered = false

    var body: some View {
        let workspace = model.workspace(ofGroup: group.id)
        #if DEBUG
        let _ = ChromeRenders.note("tab-row \(ref.hostId)/\(ref.tab.rawValue)")
        #endif
        let isActive = model.destination == .terminal && model.shownTab == ref
        let state = AgentState.mostUrgent(tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) })
        let program = model.programIdentity(of: tab, onGroup: group.id)
        let title = workspace?.title(of: tab, agentName: program.kind == .agent ? program.displayName : nil) ?? tab.title ?? "Shell"
        let context = workspace?.context(of: tab)
        let started = program.kind == .agent ? nil : workspace?.runningCommand(of: tab)
        let running = started.flatMap { $0.startedAtMs == longRunning ? $0 : nil }
        let worktree = model.groups.worktree(of: ref)
        let status = Self.statusLine(
            program: program, state: state, question: state == .blocked ? workspace?.agentQuestion(of: tab) : nil,
            since: model.agentSince(ofPane: tab.focused, onGroup: group.id))
        let informative = status == nil ? context.flatMap { Self.isInformative($0, title: title) ? $0 : nil } : nil
        let host = showsHost ? group.name : nil
        let trailing = TabRowAccessory.pick(
            isSelecting: model.isSelectingTabs, isSelected: model.tabSelection.contains(ref),
            shortcut: CommandKeyState.shared.held ? model.groups.shortcutNumber(of: ref) : nil, state: state,
            paneCount: tab.root.panes.count, opensPanes: listStyle == .plain, isExpanded: model.expandedTabs.contains(ref),
            isHovered: showsHoverAccessories, needsAttention: model.attention.contains(ref),
            hasDiff: worktree.map { $0.added > 0 || $0.removed > 0 } ?? false,
            hasPresence: !TabPresence.value(workspace, tab.root.panes).isEmpty)

        Button {
            model.clickTab(ref, modifiers: ClickModifiers.current)
        } label: {
            HStack(alignment: .center, spacing: DS.Space.gap10) {
                SidebarTabIcon(program: program, state: state, isSelected: isActive && !model.isSelectingTabs)
                    .attentionCue(trigger: model.attention.beat(of: ref))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Space.row) {
                        Text(title)
                            .font(SidebarFont.title)
                            // Finished work not yet looked at, until it is opened.
                            .fontWeight(state == .done && !isActive ? .semibold : .regular)
                            .lineLimit(1)
                            // A path keeps its end: the directory you are in.
                            .truncationMode(title.hasPrefix("/") || title.hasPrefix("~") ? .head : .tail)
                            .shimmering(state == .working, text: title)
                            .foregroundStyle(SidebarRowInk.title(selected: isActive && !model.isSelectingTabs))
                        if tab.zoomed != nil {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    // Nothing to say under the title: one line, centred on the icon, not a
                    // blank second line that pushes the title up.
                    if status != nil || informative != nil || running != nil || worktree != nil || host != nil {
                        // In a project it leads with the host, which the section header doesn't name.
                        TabSubtitle(context: informative, running: running, worktree: worktree, host: host, status: status,
                                    program: program.isShell ? nil : program.displayName)
                            .motionTransition(.fade)
                    }
                }
                .animation(DS.Motion.standard, value: status != nil || informative != nil || running != nil)
                Spacer(minLength: DS.Space.xs)
                accessory(trailing, worktree: worktree, workspace: workspace, isActive: isActive)
            }
            .opacity(group.showsAsLive ? 1 : 0.6)
            // A step in from its project's or host's header.
            .padding(.leading, DS.Space.xs)
            // In Select mode only the checks say what is selected.
            .sidebarRow(selected: isActive && !model.isSelectingTabs)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .task(id: started?.startedAtMs) {
            guard let started else { return longRunning = nil }
            let ranFor = Date.now.timeIntervalSince1970 - Double(started.startedAtMs) / 1000
            try? await Task.sleep(for: .seconds(max(0, Double(TabSubtitle.threshold) - ranFor)))
            if !Task.isCancelled { longRunning = started.startedAtMs }
        }
        #if os(macOS)
        .simultaneousGesture(TapGesture(count: 2).onEnded { perform(.rename) })
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TabLeadingMark.label(title: title, program: program, state: state, host: group.name))
        .accessibilityValue([worktree.map(TabGitBadges.accessibilityValue) ?? "", running.map { "Running: \($0.command ?? "a command")" } ?? context ?? "", TabPresence.value(workspace, tab.root.panes)]
            .filter { !$0.isEmpty }.joined(separator: "; "))
        .accessibilityAddTraits(isActive || model.isInMultipleSelection(ref) ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tab-row-\(number)")
        .rowActions(actions, id: ref.description, name: title, perform: perform) {
            if model.isInMultipleSelection(ref) {
                TabSelectionMenuItems(model: model)
            } else {
                if WindowRequest.isSupported {
                    Button(RowAction.openInNewWindow.title, systemImage: RowAction.openInNewWindow.systemImage) { model.openInNewWindow(ref) }
                        .accessibilityIdentifier("open-in-new-window")
                }
                if let workspace { MergeIntoTabMenu(workspace: workspace, tab: tab.id) }
                if let worktree {
                    Button("New Agent in \(worktree.repoName)", systemImage: "sparkle") { model.newAgent(onGroup: group.id, repo: worktree.repo) }
                }
                Divider()
                ProjectMenuItems(model: model, ref: ref)
                Divider()
                Button("Select Tabs", systemImage: "checkmark.circle") {
                    withAnimation(DS.Motion.standard) {
                        model.isSelectingTabs = true
                        model.tabSelection.select(ref)
                    }
                }
            }
        }
        .accessibilityAction(named: "Move Up") { withAnimation(DS.Motion.standard) { model.groups.moveTab(ref, by: -1) } }
        .modifier(PaneTreeActions(ref: ref, paneCount: tab.root.panes.count, opens: listStyle == .plain))
        .accessibilityAction(named: "Move Down") { withAnimation(DS.Motion.standard) { model.groups.moveTab(ref, by: 1) } }
    }

    /// Touch has no hover: the panes chevron stays.
    private var showsHoverAccessories: Bool {
        #if os(macOS)
        hovered
        #else
        true
        #endif
    }

    @ViewBuilder private func accessory(_ accessory: TabRowAccessory, worktree: TabWorktree?, workspace: Workspace?, isActive: Bool) -> some View {
        Group {
            switch accessory {
            case .selection(let selected):
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected ? DS.Palette.accent : DS.Palette.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            case .shortcut(let number):
                TabShortcut(number: number)
            case .pill(let state):
                StatePill(state)
            case .panes(let expanded):
                TreeChevron(isExpanded: expanded) {
                    withAnimation(DS.Motion.standard) { model.expandedTabs.formSymmetricDifference([ref]) }
                }
            case .attention:
                AttentionDot()
            case .diff:
                if let worktree { TabGitBadges(worktree: worktree, selected: isActive, showsPullRequest: false) }
            case .presence:
                TabPresence(workspace: workspace, panes: tab.root.panes)
            case .none:
                EmptyView()
            }
        }
        .id(accessory)
        .motionTransition(.pill(anchor: .trailing))
    }

    private var actions: RowActions {
        let busy = tab.root.panes.contains { pane in
            let state = model.agentState(ofPane: pane, onGroup: group.id)
            return state == .working || state == .blocked
        }
        return RowActions(.terminalTab(isBusy: busy))
    }

    private func perform(_ action: RowAction) {
        switch action {
        case .rename:
            model.focus(ref)
            model.workspace(ofGroup: group.id)?.renamingTab = tab.id
        case .closeTab:
            model.closeTab(ref, undoable: actions.undoable.contains(.closeTab))
        default:
            break
        }
    }

    /// An agent tab's kind, state and how long, and what it asks while it waits.
    static func statusLine(program: ProgramIdentity, state: AgentState?, question: String?, since: Date?) -> AgentStatusLine? {
        guard program.kind == .agent, let state, state != .unknown else { return nil }
        return AgentStatusLine(kind: program.displayName, state: state, since: since, question: question)
    }

    /// A context line worth a second line in the row.
    static func isInformative(_ context: String, title: String) -> Bool {
        let trimmed = context.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != "~" && trimmed != title
    }
}

/// The sidebar's footer on the Mac. On iPad Settings sits in the sidebar's top bar instead,
/// clear of the keyboard and its key bar.
private struct SidebarFooter: View {
    @Environment(WindowModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        #if os(macOS)
        let update = AppUpdater.shared.prompt
        VStack(spacing: DS.Space.s) {
            if update.showsCard {
                UpdateCard(prompt: update)
                    .motionTransition(.toast(from: .bottom))
            }
            buttons(update: update)
        }
        .padding(.top, update.showsCard ? DS.Space.s : 0)
        .animation(DS.Motion.standard, value: update.showsCard)
        .background(UpdateSidebarAnchor(model: model))
        // Opaque: rows scroll under it.
        .chromeBackground(DS.Palette.sidebar)
        #else
        buttons()
            .chromeBackground(DS.Palette.sidebar)
        #endif
    }

    #if os(macOS)
    private func buttons(update: UpdatePrompt) -> some View {
        buttonRow {
            if update.showsIndicator {
                UpdateIndicator(prompt: update)
                    .motionTransition(.pill())
            }
        }
    }
    #else
    private func buttons() -> some View {
        buttonRow { EmptyView() }
    }
    #endif

    private func buttonRow(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: DS.Space.s) {
            Button {
                withAnimation(DS.Motion.standard) { model.newEmptyProject() }
            } label: {
                Label(WorkspaceAction.newProject.title, systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(SidebarFont.subtitle)
            }
            .buttonStyle(.bar)
            .foregroundStyle(DS.Palette.textSecondary)
            .help("New Project (⌃⌘N)")
            .accessibilityIdentifier("sidebar-new-project")
            Spacer()
            trailing()
            Button("Settings", systemImage: "gearshape") {
                #if os(macOS)
                openWindow(id: SettingsWindow.id)
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

/// iPhone (compact width): one pane full screen under a slim bar whose title opens the tab
/// switcher.
struct CompactTerminalView: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Environment(\.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if !model.isEditorFullScreen { bar }
            TerminalArea(workspace: workspace, compact: true)
        }
        .chromeContent()
        .chromeBackground(DS.Palette.base)
        .modifier(ProjectNamingAlert())
        #if os(iOS)
        // The tab overview selects in its own list.
        .sheet(isPresented: Binding(get: { model.isSelectingTabs && model.sheet != .tabs }, set: { if !$0 { model.endTabSelection() } })) {
            CompactTabSelection()
                .environment(model)
                .chromeSheetBackground()
        }
        #endif
    }

    private var bar: some View {
        HStack(spacing: DS.Space.xs) {
            tabSwitcher
            Spacer()
            if model.destination == .terminal, let worktree = model.git.worktree {
                PRToolbarButton(git: model.git, worktree: worktree)
            }
            if let mixed = model.activeMixed {
                // One leaf of a mixed tab shows at a time.
                if mixed.leaves.count > 1 { mixedPaneSwitcher(mixed) }
            } else if let tab = workspace.session.activeTab, tab.root.panes.count > 1 {
                paneSwitcher(tab)
            }
            #if os(iOS)
            if model.destination == .terminal, model.activeMixed == nil, let id = workspace.focusedPane,
               let pane = workspace.panes[id], let chat = pane.chat, chat.agent != nil, chat.offersChat {
                PaneChatButton(pane: pane, state: chat)
            }
            #endif
            Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
                .labelStyle(.iconOnly)
                .help("Command Palette (⌘K)")
                .accessibilityIdentifier("open-palette")
            NewTabButton(workspace: workspace)
        }
        .buttonStyle(.bar)
        .padding(.horizontal, DS.Space.s)
        // A 36 pt bar with a two-line title: grows with Dynamic Type only as far as it fits.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .frame(height: 36)
    }

    private var tabSwitcher: some View {
        let total = model.groups.tabs.count
        let restorable = model.groups.restorableTabs.count
        return Menu {
            ControlGroup {
                Button("Select", systemImage: "checkmark.circle") { model.isSelectingTabs = true }
                    .disabled(total < 2)
                Button(WorkspaceAction.newProject.title, systemImage: "folder.badge.plus") { model.newEmptyProject() }
                Button("Show All", systemImage: "arrow.up.left.and.arrow.down.right") { model.sheet = .tabs }
            }
            if restorable > 0 || !model.idleTabs.isEmpty || !model.recentlyClosed.tabs.isEmpty {
                Section {
                    if restorable > 0 {
                        Button(restorable == 1 ? "Restore 1 Tab" : "Restore \(restorable) Tabs", systemImage: "arrow.counterclockwise") { model.restoreHiddenTabs() }
                    }
                    if !model.idleTabs.isEmpty {
                        Button("Close \(model.idleTabs.count) Idle Tabs", systemImage: "moon.zzz") { model.closeIdleTabs() }
                    }
                    if !model.recentlyClosed.tabs.isEmpty {
                        Menu("Recently Closed", systemImage: "clock.arrow.circlepath") {
                            RecentlyClosedMenuItems(model: model, limit: 10)
                        }
                    }
                }
            }
            ForEach(model.switcherSections) { section in
                switch section.kind {
                case .project(let id):
                    if let project = model.groups.project(id) {
                        Section {
                            projectItem(project)
                            ForEach(section.tabs, id: \.self) { ref in
                                switcherItem(ref, showsHost: project.hosts.count > 1)
                            }
                        }
                    }
                case .window:
                    Section("This Window") {
                        ForEach(section.tabs, id: \.self) { ref in switcherItem(ref) }
                    }
                case .host(let id):
                    if let group = model.groups.group(id) {
                        Section(group.name) {
                            ForEach(section.tabs, id: \.self) { ref in switcherItem(ref) }
                            if group.isLocal || group.isReady {
                                Button("New Terminal on \(group.name)", systemImage: "plus") { model.newTab(onGroup: group.id) }
                            }
                        }
                    }
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
                    ProgramTile(model.programIdentity(of: tab, onGroup: workspace.groupId))
                }
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
        .menuOrder(.fixed)
        .accessibilityIdentifier("tab-switcher")
    }

    /// A tab in the switcher: its title (and host, in a project across hosts) with a checkmark
    /// when current, the agent's state glyph while it has something to say, else the program's
    /// mark.
    private func switcherItem(_ ref: TabRef, showsHost: Bool = false) -> some View {
        let title = model.title(ofTab: ref)
        return Button {
            model.focus(ref)
        } label: {
            Text(title)
            if showsHost { Text(model.groupName(ref.hostId)) }
            switcherIcon(ref)
        }
    }

    private func switcherIcon(_ ref: TabRef) -> Image {
        if model.currentTab == ref { return Image(systemName: "checkmark") }
        if let mixed = ref.hostId == HostGroups.mixedId ? model.composites.tab(ref.tab) : nil {
            return Image(systemName: mixed.isEditorOnly ? "chevron.left.forwardslash.chevron.right" : mixed.isBrowserOnly ? "globe" : "rectangle.split.2x1")
        }
        guard let tab = model.groups.group(ref.hostId)?.tabs.first(where: { $0.id == ref.tab }) else { return Image(systemName: "terminal") }
        if let state = switcherAgentState(tab, ref: ref) {
            return Image(systemName: state.symbol)
        }
        return model.programIdentity(of: tab, onGroup: ref.hostId).image
    }

    private func switcherAgentState(_ tab: Tab, ref: TabRef) -> AgentState? {
        let state = AgentState.mostUrgent(tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: ref.hostId) })
        return state == .idle || state == .unknown ? nil : state
    }

    /// A project's first line in the switcher: its colour, name and where its tabs are; its
    /// menu holds what the sidebar header's does.
    private func projectItem(_ project: Project) -> some View {
        Menu {
            ProjectMenu(project: project, collapsed: nil) { model.namingProject = project.id }
        } label: {
            Text(project.name)
            Text(model.switcherSubtitle(of: project))
            projectIcon(project.color)
        }
    }

    /// The project's colour on a folder. A menu draws its icons in one colour unless the image
    /// carries its own.
    private func projectIcon(_ color: Int) -> Image {
        #if os(iOS)
        let tint = UIColor(Color(DS.Palette.project(color).resolve(in: environment)))
        if let folder = UIImage(systemName: "folder.fill")?.withTintColor(tint, renderingMode: .alwaysOriginal) {
            return Image(uiImage: folder)
        }
        #endif
        return Image(systemName: "folder.fill")
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
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
    }

    private func mixedPaneSwitcher(_ mixed: CompositeTab) -> some View {
        Menu {
            Picker("Pane", selection: Binding(get: { mixed.focusedLeaf }, set: { model.focusLeaf($0, inMixedTab: mixed.id) })) {
                ForEach(Array(mixed.leaves.enumerated()), id: \.element) { index, leaf in
                    mixedLeafLabel(mixed, leaf, index: index).tag(leaf)
                }
            }
        } label: {
            Label("Panes", systemImage: "rectangle.split.2x1")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
    }

    @ViewBuilder private func mixedLeafLabel(_ mixed: CompositeTab, _ leaf: PaneId, index: Int) -> some View {
        if let browser = mixed.browsers[leaf] {
            Label(URL(string: browser.url)?.host() ?? "Browser", systemImage: "globe")
        } else if let editor = mixed.editors[leaf] {
            Label("VS Code · \(editor.folderName)", systemImage: "chevron.left.forwardslash.chevron.right")
        } else if let tool = mixed.tools[leaf] {
            Text(tool.tool.title)
        } else if let member = mixed.members[leaf] {
            let program = model.programIdentity(ofPane: member.pane, onGroup: member.hostId)
            Label { Text(program.isShell ? "Pane \(index + 1)" : program.displayName) } icon: { program.image }
        }
    }
}

/// iPhone: a project just made is named in an alert (the switcher is a menu, with no room to
/// type), as tabs are renamed.
private struct ProjectNamingAlert: ViewModifier {
    @Environment(WindowModel.self) private var model
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            // The tab overview names a project in place, as the sidebar does.
            .alert("Name Project", isPresented: Binding(get: { model.namingProject != nil && model.sheet != .tabs }, set: { if !$0 { model.namingProject = nil } })) {
                TextField("Project Name", text: $draft)
                Button("Done") { if let id = model.namingProject { model.renameProject(id, to: draft) } }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: model.namingProject, initial: true) { _, id in
                draft = id.flatMap { model.groups.project($0)?.name } ?? ""
            }
    }
}

// MARK: - Shared

/// Shows or hides the sidebar (⌘B). Hidden, the tabs move to the strip on top; its context menu
/// turns that strip off for a terminal that fills the window.
struct SidebarToggle: View {
    @Environment(WindowModel.self) private var model
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true

    var body: some View {
        // Hidden, the sidebar's rows can't show a tab that called for you: the toggle does.
        let calls = !model.isSidebarShown && !model.attention.isEmpty
        Button {
            WorkspaceAction.toggleSidebar.perform(window: model)
        } label: {
            Label {
                Text(model.isSidebarShown ? "Hide Sidebar" : "Show Sidebar")
            } icon: {
                Image(systemName: "sidebar.leading")
                    .overlay(alignment: .topTrailing) {
                        if calls {
                            AttentionDot()
                                .offset(x: DS.Size.attentionDot / 2, y: -DS.Size.attentionDot / 2)
                                .motionTransition(.pill())
                        }
                    }
                    .animation(DS.Motion.micro, value: calls)
            }
        }
        .help(model.isSidebarShown ? "Hide Sidebar (⌘B)" : "Show Sidebar (⌘B)")
        .accessibilityValue(calls ? "A tab wants attention" : "")
        .tint(.primary)
        .contextMenu {
            Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
        }
        .accessibilityIdentifier("toggle-sidebar")
    }
}

/// Rename / Open in New Window / Merge / Close for a tab, shared by the strip and the compact switcher.
struct TabMenu: View {
    let tab: Tab
    let workspace: Workspace
    @Environment(WindowModel.self) private var model

    var body: some View {
        Group {
            Button("Rename…", systemImage: "pencil") { workspace.renamingTab = tab.id }
            if WindowRequest.isSupported {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                    model.openInNewWindow(TabRef(hostId: workspace.hostId ?? HostGroups.localId, tab: tab.id))
                }
            }
            MergeIntoTabMenu(workspace: workspace, tab: tab.id)
            ProjectMenuItems(model: model, ref: TabRef(hostId: workspace.groupId, tab: tab.id))
            Button(RowAction.closeTab.title, systemImage: RowAction.closeTab.systemImage, role: .destructive) {
                model.closeTab(TabRef(hostId: workspace.groupId, tab: tab.id), undoable: true)
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
