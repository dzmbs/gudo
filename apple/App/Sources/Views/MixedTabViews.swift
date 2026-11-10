import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
#if os(iOS)
import GameController
#endif

/// A mixed tab's tree: each leaf resolves through its own host's workspace in this window.
struct MixedTabTree: PaneTree {
    let model: WindowModel
    let id: TabId
    /// Whether this tab holds the window's focus (false: the other column).
    var isActive = true

    private var tab: CompositeTab? { model.composites.tab(id) }

    func resolve(_ leaf: PaneId) -> (workspace: Workspace, pane: PaneId)? {
        guard let member = tab?.members[leaf], let workspace = model.workspace(ofGroup: member.hostId) else { return nil }
        return (workspace, member.pane)
    }

    var focusedLeaf: PaneId? { isActive ? tab?.focusedLeaf : nil }

    func editor(_ leaf: PaneId) -> EditorMember? { tab?.editors[leaf] }

    func browser(_ leaf: PaneId) -> BrowserMember? { tab?.browsers[leaf] }

    func tool(_ leaf: PaneId) -> ToolMember? { tab?.tools[leaf] }

    func focus(leaf: PaneId) {
        model.focusLeaf(leaf, inMixedTab: id)
    }

    func resize(leaf: PaneId, _ direction: Direction, amount: Double) {
        model.composites.apply(.resize(leaf, direction, amount: amount), to: id)
    }

    /// Every host draws with the same font, so any measured pane's cell will do.
    var cellSize: CGSize? { model.workspace?.cellSize ?? model.workspaces.values.lazy.compactMap(\.cellSize).first }
    var padding: CGFloat { model.workspace?.appearance.padding ?? model.workspaces.values.first?.appearance.padding ?? 0 }
    var namesHosts: Bool { true }
}

/// What the terminal area shows: two columns, a mixed tab, or the active host tab.
struct TerminalArea: View {
    let workspace: Workspace
    var compact = false
    @Environment(WindowModel.self) private var model

    var body: some View {
        content
            #if os(iOS)
            .modifier(KeyboardRoom(workspace: workspace))
            #endif
    }

    @ViewBuilder private var content: some View {
        if model.isEditorFullScreen, let editor = model.activeMixed?.focusedEditor {
            FullScreenEditorView(member: editor)
        } else if !compact, model.columns != nil {
            TwoColumnsView()
        } else if let mixed = model.activeMixed {
            MixedTabView(id: mixed.id, compact: compact)
                // Never reuse one tab's pane views for another's.
                .id(WindowModel.mixedRef(mixed.id))
        } else {
            ActiveTabView(workspace: workspace, compact: compact)
                // Pane ids are per host: never reuse one host's pane views for another's.
                .id(ObjectIdentifier(workspace))
        }
    }
}

#if os(iOS)
/// The terminals' bottom at the software keyboard's top, as UIKit reports it. SwiftUI's own
/// avoidance can stop short when the key bar grows mid-slide and catch up only on a later
/// layout (focus moving to another pane): the room it leaves is topped up here, in the same
/// layout pass, so each keyboard change resizes the panes once and focus moving between panes
/// with the keyboard up resizes none.
private struct KeyboardRoom: ViewModifier {
    let workspace: Workspace

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .padding(.bottom, workspace.keyboardTop.map { max(0, proxy.frame(in: .global).maxY - $0) } ?? 0)
        }
    }
}
#endif

/// An editor alone in the window (⌃⌘F): the workbench edge to edge, with the way back always
/// on it (`ExitFullScreenControl`). Escape stays VS Code's.
struct FullScreenEditorView: View {
    let member: EditorMember
    @Environment(WindowModel.self) private var model
    @State private var pointer: CGPoint?
    @AppStorage(ExitFullScreenControl.spotKey) private var spot = ExitFullScreenControl.Spot.bottomTrailing

    var body: some View {
        EditorLeafView(member: member, isSplit: false, isFocused: true, focus: {}, isFullScreen: true)
            .overlay {
                ExitFullScreenControl(spot: $spot, pointer: pointer) { model.toggleEditorFullScreen() }
            }
            .toastHost(model.fullScreenHints, bottomInset: ExitFullScreenControl.bottomInset)
            .onContinuousHover { phase in
                if case .active(let point) = phase { pointer = point } else { pointer = nil }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-full-screen-view")
            #if os(iOS)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            #endif
    }
}

/// Exit Full Screen: a capsule spelled out on entering, then a small ⤡ that rests where it was
/// last dragged, snapping to the nearest corner or edge. A pointer coming near spells it out again.
struct ExitFullScreenControl: View {
    /// Where it rests: a corner or the middle of an edge.
    enum Spot: String, CaseIterable {
        case topLeading, top, topTrailing, leading, trailing, bottomLeading, bottom, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .top: .top
            case .topTrailing: .topTrailing
            case .leading: .leading
            case .trailing: .trailing
            case .bottomLeading: .bottomLeading
            case .bottom: .bottom
            case .bottomTrailing: .bottomTrailing
            }
        }

        var isTop: Bool { [.topLeading, .top, .topTrailing].contains(self) }
        var isBottom: Bool { [.bottomLeading, .bottom, .bottomTrailing].contains(self) }
        var isTrailing: Bool { [.topTrailing, .trailing, .bottomTrailing].contains(self) }
        var isLeading: Bool { [.topLeading, .leading, .bottomLeading].contains(self) }

        /// The collapsed glyph's centre at this spot in an area of `size`.
        func center(in size: CGSize) -> CGPoint {
            let half = ExitFullScreenControl.size / 2
            let inset = ExitFullScreenControl.sideInset
            let x = isLeading ? inset + half : isTrailing ? size.width - inset - half : size.width / 2
            let y = isTop ? ExitFullScreenControl.topInset + half
                : isBottom ? size.height - ExitFullScreenControl.bottomInset - half : size.height / 2
            return CGPoint(x: x, y: y)
        }

        /// The spot nearest `point`.
        static func nearest(to point: CGPoint, in size: CGSize) -> Spot {
            allCases.min { distance(point, $0.center(in: size)) < distance(point, $1.center(in: size)) } ?? .bottomTrailing
        }

        static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    }

    static let spotKey = "editorFullScreen.exitSpot"
    /// Clear of VS Code's title bar (35 pt) and status bar (22 pt), so none of their controls
    /// is ever covered.
    static let topInset: CGFloat = 35 + 10
    static let bottomInset: CGFloat = 22 + 10
    static let sideInset: CGFloat = 12
    static let size: CGFloat = 36
    private static let space = "exit-full-screen-area"

    @Binding var spot: Spot
    var pointer: CGPoint?
    let action: () -> Void

    @State private var isExpanded = true
    @State private var drag: CGSize = .zero
    @State private var area: CGSize = .zero
    @State private var collapse: Task<Void, Never>?
    @State private var snaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation { reduceMotion ? DS.Motion.overlay : DS.Motion.menu }

    var body: some View {
        Color.clear
            .overlay(alignment: spot.alignment) {
                control
                    .padding(.top, spot.isTop ? Self.topInset : 0)
                    .padding(.bottom, spot.isBottom ? Self.bottomInset : 0)
                    .padding(.leading, spot.isLeading ? Self.sideInset : 0)
                    .padding(.trailing, spot.isTrailing ? Self.sideInset : 0)
                    .offset(drag)
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { area = $0 }
            .coordinateSpace(.named(Self.space))
            .onAppear { reveal() }
            .onDisappear { collapse?.cancel() }
            .onChange(of: pointer) { _, point in
                guard drag == .zero else { return }
                if let point, Spot.distance(point, spot.center(in: area)) < 96 {
                    reveal(holding: true)
                } else if collapse == nil, isExpanded {
                    settle()
                }
            }
    }

    private var control: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                // The glyph stays at the edge it rests on while the words come and go.
                if spot.isTrailing { label }
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)
                if !spot.isTrailing { label }
            }
            .padding(.horizontal, isExpanded ? 14 : 0)
            .frame(minWidth: Self.size, minHeight: Self.size)
            // The words fade inside the capsule as it narrows, never past its edge.
            .clipShape(.capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .floatingCapsule(interactive: true)
        .chromeContent()
        .highPriorityGesture(dragToMove)
        .sensoryFeedback(DS.Haptic.armed, trigger: snaps)
        .onHover { inside in if inside { reveal(holding: true) } else { settle() } }
        .help("Exit Full Screen (⌃⌘F)")
        .accessibilityLabel("Exit Full Screen")
        .accessibilityValue(spot.rawValue)
        .accessibilityIdentifier("editor-exit-full-screen")
    }

    @ViewBuilder private var label: some View {
        if isExpanded {
            HStack(spacing: DS.Space.s) {
                Text("Exit Full Screen")
                    .font(.subheadline.weight(.medium))
                if Self.hasKeyboard {
                    Text("⌃⌘F")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .transition(.asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.06)),
                removal: .opacity.animation(.easeOut(duration: 0.1))))
        }
    }

    private var dragToMove: some Gesture {
        // In the area's space: the control's own moves with it.
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                collapse?.cancel()
                collapse = nil
                drag = value.translation
            }
            .onEnded { value in
                // A flick carries it on a little.
                let carry = 0.3
                let end = CGPoint(
                    x: value.location.x + (value.predictedEndLocation.x - value.location.x) * carry,
                    y: value.location.y + (value.predictedEndLocation.y - value.location.y) * carry)
                withAnimation(reduceMotion ? DS.Motion.overlay : DS.Motion.press) {
                    spot = Spot.nearest(to: end, in: area)
                    drag = .zero
                }
                snaps += 1
                settle()
            }
    }

    /// Spelled out; collapses again 2.5 s on unless `holding` (the pointer is on it).
    private func reveal(holding: Bool = false) {
        if !isExpanded { withAnimation(motion) { isExpanded = true } }
        collapse?.cancel()
        collapse = nil
        if !holding { settle(after: .seconds(2.5)) }
    }

    private func settle(after delay: Duration = .seconds(1.2)) {
        collapse?.cancel()
        collapse = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(motion) { isExpanded = false }
            collapse = nil
        }
    }

    static var hasKeyboard: Bool {
        #if os(iOS)
        GCKeyboard.coalesced != nil
        #else
        true
        #endif
    }
}

/// The first few times in full screen: how to get back, as a banner.
enum FullScreenHint {
    static let shownKey = "editorFullScreen.hintsShown"
    static let times = 3

    /// The first few times only: after that the control speaks for itself.
    @MainActor static func showIfNew(on center: ToastCenter) {
        let shown = UserDefaults.standard.integer(forKey: shownKey)
        guard shown < times else { return }
        UserDefaults.standard.set(shown + 1, forKey: shownKey)
        center.show(toast)
    }

    static var toast: Toast {
        Toast(ExitFullScreenControl.hasKeyboard ? "Press ⌃⌘F or tap ⤡ to exit. Drag ⤡ anywhere." : "Tap ⤡ to exit full screen. Drag it anywhere.",
              systemImage: "arrow.down.right.and.arrow.up.left",
              // An action keeps it up long enough to read.
              action: Toast.Action("Got It") { UserDefaults.standard.set(times, forKey: shownKey) })
    }
}

/// A mixed tab: its split tree across hosts. Each pane carries its host in its header and its
/// own host's connection state: one host going down dims that pane only, with the reconnect
/// notice or card over it, while the others stay live.
struct MixedTabView: View {
    let id: TabId
    var isActive = true
    var compact = false
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact

    var body: some View {
        if let tab = model.composites.tab(id) {
            // Compact width shows the focused pane alone, as for a host tab.
            let single = compact ? tab.focusedLeaf : tab.layout.zoomed
            let isSplit = single == nil && tab.leaves.count > 1
            SplitTreeView(node: single.map(Node.leaf) ?? tab.layout.root, tree: MixedTabTree(model: model, id: id, isActive: isActive), isSplit: isSplit, animated: !compact)
                .padding(paneStyle == .comfortable && isSplit ? DS.Space.row : 0)
                .background(paneStyle == .comfortable && isSplit ? theme.splitDivider : theme.background, ignoresSafeAreaEdges: [])
                .background(theme.background, ignoresSafeAreaEdges: [])
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    if isActive, !model.isPresentation, model.terminalArea != size { model.terminalArea = size }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("mixed-tab")
        } else {
            theme.background
        }
    }
}

/// A pane's host in a mixed tab's pane header: its glyph (the link's state glyph while it is
/// not healthy) and name.
struct HostChip: View {
    let group: HostGroup
    let emphasized: Bool
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            ConnectionGlyph(group.connectionState, healthy: Image(systemName: group.systemImage))
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
            Text(group.name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? DS.Palette.textSecondary : DS.Palette.textTertiary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(DS.Palette.hoverFill, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("on \(group.name)")
    }
}

extension View {
    /// A mixed tab's pane: its own host's connection overlay (dimmed with a notice or card while
    /// that host is down, as a host tab is), so the other hosts' panes stay live.
    @ViewBuilder func hostLinkOverlay(groupId: String, enabled: Bool) -> some View {
        if enabled {
            modifier(HostLinkOverlay(groupId: groupId))
        } else {
            self
        }
    }
}

private struct HostLinkOverlay: ViewModifier {
    let groupId: String
    @Environment(WindowModel.self) private var model

    func body(content: Content) -> some View {
        content.connectionOverlay(
            model.connectionState(ofGroup: groupId), hostName: model.groupName(groupId),
            onRetry: { model.hosts.retry(groupId) },
            onDisconnect: { model.closeHost(groupId) })
    }
}

/// The hosts of a mixed tab, as glyphs and names ("server alpha · server beta").
struct MixedHostsLine: View {
    let tab: CompositeTab
    @Environment(WindowModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(Array(tab.hosts.enumerated()), id: \.element) { index, host in
                if index > 0 {
                    Text("+").foregroundStyle(DS.Palette.textTertiary)
                }
                HStack(spacing: 2) {
                    let group = model.groups.group(host)
                    ConnectionGlyph(model.connectionState(ofGroup: host), healthy: Image(systemName: group?.systemImage ?? "server.rack"))
                        .font(.caption2)
                        .imageScale(.small)
                    Text(model.groupName(host)).lineLimit(1)
                }
            }
        }
        .font(SidebarFont.subtitle)
        .foregroundStyle(DS.Palette.textSecondary)
    }
}

// MARK: - Sidebar and strip

/// One of the window's own tabs in the sidebar: its title over its hosts.
struct MixedTabRow: View {
    let tab: CompositeTab
    let number: Int
    @Environment(WindowModel.self) private var model
    @State private var renaming = false
    @State private var draft = ""

    var body: some View {
        let ref = WindowModel.mixedRef(tab.id)
        let isActive = model.destination == .terminal && model.currentTab == ref
        let title = model.title(ofMixedTab: tab)
        let program = model.programIdentity(ofMixedTab: tab)
        let state = tab.leaves.compactMap { tab.members[$0] }
            .compactMap { model.agentState(ofPane: $0.pane, onGroup: $0.hostId) }
            .min { $0.urgency < $1.urgency }
        Button {
            withAnimation(DS.Motion.snappy) { model.focus(ref) }
        } label: {
            HStack(alignment: .center, spacing: DS.Space.gap10) {
                SidebarTabIcon(program: program, state: state, favicon: model.favicon(ofMixedTab: tab))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(SidebarFont.title)
                        .fontWeight(state == .done && !isActive ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MixedHostsLine(tab: tab)
                }
                Spacer(minLength: DS.Space.xs)
                TabNumber(number: number, shortcut: CommandKeyState.shared.held ? model.groups.shortcutNumber(of: ref) : nil)
            }
            .sidebarRow(selected: isActive)
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .simultaneousGesture(TapGesture(count: 2).onEnded { perform(.rename, busy: state == .working || state == .blocked) })
        #endif
        .alert("Rename Tab", isPresented: $renaming) {
            TextField("Title", text: $draft)
            Button("Rename") { model.composites.apply(.rename(tab.id, draft), to: tab.id) }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.isEditorOnly
            ? "\(title), VS Code on \(tab.hosts.map(model.groupName).joined(separator: " and "))"
            : tab.isBrowserOnly ? "\(title), browser"
            : "\(title), mixed: \(tab.hosts.map(model.groupName).joined(separator: " and "))")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tab-row-\(number)")
        .rowActions(actions(busy: state == .working || state == .blocked), id: ref.description, name: title) { action in
            perform(action, busy: state == .working || state == .blocked)
        } menu: {
            MergeWindowTabMenu(tab: tab.id)
            ProjectMenuItems(model: model, ref: ref)
        }
    }

    private func actions(busy: Bool) -> RowActions {
        RowActions(tab.isEditorOnly ? .editorTab : tab.isBrowserOnly ? .browserTab : .mixedTab(isBusy: busy))
    }

    private func perform(_ action: RowAction, busy: Bool) {
        switch action {
        case .rename:
            draft = tab.title ?? ""
            renaming = true
        case .closeTab, .closeEditor:
            model.closeWindowTab(tab.id, undoable: actions(busy: busy).undoable.contains(action))
        case .stopServer:
            model.stopEditorServers(inTab: tab.id)
        default:
            break
        }
    }
}

/// A mixed tab in the tab strip (sidebar hidden): its title over its hosts.
struct MixedTabChip: View {
    let tab: CompositeTab
    let isActive: Bool
    @Environment(WindowModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let ref = WindowModel.mixedRef(tab.id)
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: DS.Radius.tabPill)
                    .fill(DS.Palette.selectedFill)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.tabPill).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                    .padding(.vertical, 3)
            } else if isHovered {
                RoundedRectangle(cornerRadius: DS.Radius.tabPill)
                    .fill(DS.Palette.hoverFill)
                    .padding(.vertical, 3)
            }
            VStack(spacing: 0) {
                HStack(spacing: DS.Space.xs) {
                    if tab.isEditorOnly {
                        ProgramMark(.vscode, size: 12)
                    } else if tab.isBrowserOnly {
                        if let favicon = model.favicon(ofMixedTab: tab) {
                            Favicon(image: favicon, size: 12)
                        } else {
                            ProgramMark(.browser, size: 12)
                        }
                    }
                    Text(model.title(ofMixedTab: tab))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(tab.hosts.map(model.groupName).joined(separator: " + "))
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            .font(.callout.weight(isActive ? .medium : .regular))
            .foregroundStyle(isActive ? DS.Palette.text : DS.Palette.textSecondary)
            .padding(.horizontal, 40)
            HStack(spacing: 0) {
                Button("Close Tab", systemImage: "xmark") { model.closeMixedTab(tab.id) }
                    .labelStyle(.iconOnly)
                    .help("Close Tab (⌘W)")
                    .font(.caption2.weight(.bold))
                    .frame(width: 22, height: 22)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                Spacer(minLength: 0)
                if let number = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(number)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .padding(.trailing, DS.Space.s)
                }
            }
            .padding(.leading, 3)
        }
        .frame(height: 34)
        .contentShape(.rect)
        .onTapGesture { model.focus(ref) }
        .onHover { isHovered = $0 }
        .contextMenu {
            MergeWindowTabMenu(tab: tab.id)
            Button(RowAction.closeTab.title, systemImage: RowAction.closeTab.systemImage, role: .destructive) {
                model.closeWindowTab(tab.id, undoable: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tabbar-\(ref)")
    }
}

/// A browser or VS Code tab into another tab, as a split on the right (dragged onto a terminal
/// pane's edge, on that edge).
struct MergeWindowTabMenu: View {
    let tab: TabId
    @Environment(WindowModel.self) private var model

    var body: some View {
        let targets = model.windowTabMergeTargets(besides: tab)
        if !targets.isEmpty {
            Menu("Merge Into Tab", systemImage: "rectangle.split.2x1") {
                ForEach(targets, id: \.self) { target in
                    Button(model.title(ofTab: target)) { model.mergeWindowTab(tab, into: target) }
                }
            }
            .accessibilityIdentifier("tab-merge-into")
        }
    }
}

// MARK: - Two Columns

/// Two tabs side by side, each column its own tab (View ▸ Two Columns; on by itself on a
/// foldable's open inner screen, one column each side of the fold). The columns stay put while
/// focus moves between them: the current tab's column is the one taking the keyboard, a tab
/// picked in the sidebar replaces it, and the other column keeps its tab.
struct TwoColumnsView: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        if let columns = model.columns {
            FoldPages {
                column(columns.left, isLeft: true, isActive: model.currentColumnIsLeft)
                    .accessibilityIdentifier("column-left")
            } divider: {
                Rectangle()
                    .fill(theme.splitDivider)
                    .frame(width: DS.Size.dividerVisible)
            } trailing: {
                column(columns.right, isLeft: false, isActive: !model.currentColumnIsLeft)
                    .accessibilityIdentifier("column-right")
            }
            .background(theme.background, ignoresSafeAreaEdges: [])
        }
    }

    @ViewBuilder private func column(_ ref: TabRef?, isLeft: Bool, isActive: Bool) -> some View {
        Group {
            if let ref {
                TabColumn(ref: ref, isLeft: isLeft, isActive: isActive)
                    .id(ref)
            } else {
                EmptyColumn()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// One column: a header naming the tab and its host, then the tab's panes. The column without
/// focus dims like an unfocused split (Ghostty's unfocused-split-opacity).
private struct TabColumn: View {
    let ref: TabRef
    let isLeft: Bool
    let isActive: Bool
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var unfocusedOpacity = TerminalPreferences.Default.unfocusedSplitOpacity

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(ref: ref, isLeft: isLeft, isActive: isActive)
            content
                .overlay {
                    if !isActive { UnfocusedDim(unfocusedSplitOpacity: unfocusedOpacity, fill: theme.background).allowsHitTesting(false) }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if ref.hostId == HostGroups.mixedId {
            MixedTabView(id: ref.tab, isActive: isActive)
        } else if let workspace = model.workspace(ofGroup: ref.hostId),
                  let tab = workspace.session.tabs.first(where: { $0.id == ref.tab })
        {
            let isSplit = tab.zoomed == nil && tab.root.panes.count > 1
            SplitTreeView(
                node: tab.zoomed.map(Node.leaf) ?? tab.root,
                tree: HostTabTree(workspace: workspace, tab: tab.id, model: model, isActive: isActive), isSplit: isSplit)
                .id(ref)
                .connectionOverlay(
                    model.connectionState(ofGroup: ref.hostId), hostName: model.groupName(ref.hostId),
                    onRetry: { model.hosts.retry(ref.hostId) }, onDisconnect: { model.closeHost(ref.hostId) })
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    if isActive, !model.isPresentation, model.terminalArea != size { model.terminalArea = size }
                }
        } else {
            theme.background
        }
    }
}

/// A column's title strip: the tab's mark and name, and its host; tap to work in that column.
private struct ColumnHeader: View {
    let ref: TabRef
    let isLeft: Bool
    let isActive: Bool
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        let (title, host, program) = describe()
        HStack(spacing: DS.Space.row) {
            ProgramMark(program, size: 12)
                .foregroundStyle(isActive ? DS.Palette.text : DS.Palette.textSecondary)
            Text(title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? DS.Palette.text : DS.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let host {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: 26)
        .background(theme.background, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(theme.splitDivider).frame(height: 1) }
        .contentShape(.rect)
        .onTapGesture { if !isActive { model.focus(ref) } }
        // Drag a column by its header onto the other to trade pages; drop any tab here to show it.
        .tabDrag(ref, model: model)
        .dropDestination(for: String.self) { _, _ in
            guard let dragged = model.draggedTab else { return false }
            model.draggedTab = nil
            withAnimation(DS.Motion.fold) { model.place(dragged, inLeftColumn: isLeft) }
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func describe() -> (String, String?, ProgramIdentity) {
        if ref.hostId == HostGroups.mixedId, let tab = model.composites.tab(ref.tab) {
            return (model.title(ofMixedTab: tab), tab.hosts.map(model.groupName).joined(separator: " + "), model.programIdentity(ofMixedTab: tab))
        }
        guard let workspace = model.workspace(ofGroup: ref.hostId),
              let tab = workspace.session.tabs.first(where: { $0.id == ref.tab })
        else { return ("", nil, .shell) }
        let multiHost = model.groups.groups.count > 1
        return (workspace.title(of: tab), multiHost ? model.groupName(ref.hostId) : nil, model.programIdentity(of: tab, onGroup: ref.hostId))
    }
}

/// The second column before there is a second tab: pick one in the sidebar, or open one here.
private struct EmptyColumn: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "rectangle.righthalf.inset.filled")
                .font(.title)
                .imageScale(.large)
                .foregroundStyle(DS.Palette.textTertiary)
            Text("Choose a tab for this column, or open a new one.")
                .font(.callout)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Button("New Tab", systemImage: "plus") { model.newTabInOtherColumn() }
                .help("New Tab in This Column")
                .buttonStyle(.glass)
                .accessibilityIdentifier("column-new-tab")
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background, ignoresSafeAreaEdges: [])
    }
}
