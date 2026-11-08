import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Equal-width horizontal tabs after Ghostty's macOS tab bar, every host's tabs in sidebar order.
struct TabBar: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @State private var widths = TabStripWidths()

    var body: some View {
        let active = model.destination == .terminal ? model.currentTab : nil
        let refs = chipRefs
        HStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    chips(active: active)
                        .animation(DS.Motion.snappy, value: refs)
                }
                .scrollIndicators(.never)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in widths.stripWidth = width }
                .onChange(of: refs) { old, new in
                    withAnimation(DS.Motion.snappy) { widths.tabsChanged(to: new.count) }
                    if new.count > old.count { TabTimeline.mark(.chipInserted) }
                }
                .onChange(of: active, initial: true) { _, ref in
                    guard let ref else { return }
                    withAnimation(DS.Motion.snappy) { scroller.scrollTo(ref) }
                    TabTimeline.mark(.scrolledIntoView)
                }
            }
            NewTabButton(workspace: workspace)
                .padding(.leading, DS.Space.xs)
        }
        .buttonStyle(.bar)
        .padding(.horizontal, DS.Space.row)
        .frame(height: DS.Size.tabStrip)
        .background(DS.Palette.base)
        .overlay(alignment: .bottom) { Hairline(style: DS.Palette.separator) }
        // A 34 pt strip: titles grow with Dynamic Type only as far as it holds them.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .onHover { inside in
            if inside {
                widths.isPointerInside = true
            } else {
                withAnimation(DS.Motion.quick) { widths.pointerLeft() }
            }
        }
        .onAppear { widths.tabsChanged(to: refs.count) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-bar")
    }

    /// Every chip in strip order: window tabs, then each host's tabs.
    private var chipRefs: [TabRef] {
        let windowTabs = model.composites.ordered.map { WindowModel.mixedRef($0.id) }
        return windowTabs + model.groups.groups.flatMap { group in group.tabs.map { group.ref($0.id) } }
    }

    private func chips(active: TabRef?) -> some View {
        let groups = model.groups.groups
        let allTabs = model.groups.tabs
        let activeIndex = active.flatMap { allTabs.firstIndex(of: $0) }
        let width = widths.chipWidth
        // Tabs name their host only while the window holds more than one host.
        let isMultiHost = Set(allTabs.map(\.hostId)).count > 1
        return HStack(spacing: 0) {
            ForEach(model.composites.ordered) { tab in
                let ref = WindowModel.mixedRef(tab.id)
                MixedTabChip(tab: tab, isActive: ref == active)
                    .frame(width: width)
                    .id(ref)
                    .modifier(ChipFrameReport(ref: ref))
                    .transition(.opacity)
                Hairline(.vertical, style: DS.Palette.separator).frame(height: 16)
            }
            ForEach(groups) { group in
                ForEach(group.tabs) { tab in
                    let ref = group.ref(tab.id)
                    let index = allTabs.firstIndex(of: ref) ?? 0
                    if index > 0 {
                        // Ghostty/AppKit draw no separator next to the selected tab.
                        Hairline(.vertical, style: DS.Palette.separator)
                            .frame(height: 16)
                            .opacity(index == activeIndex || index - 1 == activeIndex ? 0 : 1)
                    }
                    TabChip(tab: tab, ref: ref, group: group, isActive: ref == active, showsHost: isMultiHost)
                        .frame(width: width)
                        .id(ref)
                        .modifier(ChipFrameReport(ref: ref))
                        .transition(.opacity)
                }
            }
        }
    }
}

#if DEBUG
extension EnvironmentValues {
    /// Tests: each strip chip's frame in the window, whenever its layout changes.
    @Entry var tabChipFrames: (@MainActor (TabRef, CGRect) -> Void)?
}
#endif

private struct ChipFrameReport: ViewModifier {
    let ref: TabRef
    #if DEBUG
    @Environment(\.tabChipFrames) private var report
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        if let report {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in report(ref, frame) }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Chips share the strip within `DS.Size.tabMinWidth...tabMaxWidth`; a tab added or closed under the pointer holds the width until the pointer leaves.
struct TabStripWidths: Equatable {
    var stripWidth: CGFloat = 0 {
        didSet { if stripWidth != oldValue { heldWidth = nil } }
    }
    var isPointerInside = false
    private(set) var count = 0
    private(set) var heldWidth: CGFloat?

    var chipWidth: CGFloat { heldWidth ?? share(of: count) }

    func share(of count: Int) -> CGFloat {
        guard count > 0, stripWidth > 0 else { return DS.Size.tabMaxWidth }
        let equal = (stripWidth / CGFloat(count)).rounded(.down)
        return min(DS.Size.tabMaxWidth, max(DS.Size.tabMinWidth, equal))
    }

    mutating func tabsChanged(to newCount: Int) {
        guard newCount != count else { return }
        let hadTabs = count > 0
        let isInsertion = newCount > count
        let shownWidth = chipWidth
        count = newCount
        if hadTabs, count > 0, isInsertion || isPointerInside, shownWidth != share(of: count) {
            heldWidth = shownWidth
        } else if !isPointerInside {
            heldWidth = nil
        }
    }

    mutating func pointerLeft() {
        isPointerInside = false
        heldWidth = nil
    }
}

private struct TabChip: View {
    let tab: Tab
    let ref: TabRef
    let group: HostGroup
    let isActive: Bool
    /// The window holds tabs from more than one host: name the host under the title.
    let showsHost: Bool
    @Environment(WindowModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let workspace = model.workspace(ofGroup: group.id)
        let states = tab.root.panes.compactMap { model.agentState(ofPane: $0, onGroup: group.id) }
        let state = states.min { $0.urgency < $1.urgency }
        let title = workspace?.title(of: tab) ?? tab.title ?? "Shell"
        let program = model.programIdentity(of: tab, onGroup: group.id)
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: DS.Radius.tabPill)
                    .fill(DS.Palette.selectedFill)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.tabPill).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
                    .padding(.vertical, 3)
                    .transition(.opacity)
            } else if isHovered {
                RoundedRectangle(cornerRadius: DS.Radius.tabPill)
                    .fill(DS.Palette.hoverFill)
                    .padding(.vertical, 3)
            }

            HStack(spacing: DS.Space.row) {
                TabLeadingMark(program: program, state: isActive ? nil : state)
                VStack(spacing: 0) {
                    Text(title)
                        .lineLimit(1)
                        // A path keeps its end: the directory you are in.
                        .truncationMode(title.hasPrefix("/") || title.hasPrefix("~") ? .head : .middle)
                    if showsHost {
                        Text(group.name)
                            .font(DS.Font.meta)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                TabPresence(workspace: workspace, panes: tab.root.panes)
            }
            // Inactive tabs dim by opacity rather than colour, so glyph colours survive.
            .font(DS.Font.tabTitle)
            .foregroundStyle(.primary)
            .opacity((isActive ? 1 : isHovered ? DS.Opacity.inactiveHover : DS.Opacity.inactive) * (group.showsAsLive ? 1 : 0.6))
            .padding(.horizontal, 40)

            HStack(spacing: 0) {
                Button("Close Tab", systemImage: "xmark") { model.closeTab(ref, undoable: false) }
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.bold))
                    .frame(width: 22, height: 22)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                    .help("Close Tab (⌘W)")
                Spacer(minLength: 0)
                if CommandKeyState.shared.held, let number = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(number)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.trailing, DS.Space.s)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 3)
            .animation(DS.Motion.quick, value: CommandKeyState.shared.held)
        }
        .frame(height: DS.Size.tabStrip)
        .animation(DS.Motion.quick, value: isActive)
        .contentShape(.rect)
        .onTapGesture { model.focus(ref) }
        .onHover { hovering in withAnimation(DS.Motion.hover) { isHovered = hovering } }
        .contextMenu {
            if let workspace {
                Button("Rename…", systemImage: "pencil") {
                    model.focus(ref)
                    workspace.renamingTab = tab.id
                }
                if WindowRequest.isSupported {
                    Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openInNewWindow(ref) }
                }
                MergeIntoTabMenu(workspace: workspace, tab: tab.id)
                ProjectMenuItems(model: model, ref: ref)
                Button("Close Tab", systemImage: "xmark", role: .destructive) { model.closeTab(ref, undoable: false) }
            }
        }
        .overlay(alignment: .bottom) {
            if let project = model.groups.project(of: ref) {
                Capsule()
                    .fill(DS.Palette.project(project.color))
                    .frame(height: 2)
                    .padding(.horizontal, DS.Space.m)
                    .accessibilityHidden(true)
            }
        }
        .tabDrag(ref, model: model)
        .dropDestination(for: String.self) { items, _ in
            // Takes the dragged tab's place in this tab's section (its project or host); only
            // that tab's own drag, not text that happens to arrive while it is remembered.
            guard let dragged = model.draggedTab, dragged != ref, items == [dragged.description],
                  let section = model.groups.sections.first(where: { $0.rows.contains(ref) }),
                  SidebarDrop.accepts(section.container, dragged),
                  let index = section.rows.firstIndex(of: ref)
            else { return false }
            model.draggedTab = nil
            withAnimation(DS.Motion.reorder) { model.commit(.insert(dragged, into: section.container, at: index)) }
            return true
        }
        .help(Self.tooltip(title: title, host: group.isLocal ? nil : group.name, directory: workspace?.directory(of: tab), context: workspace?.context(of: tab)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TabLeadingMark.label(title: title, program: program, state: isActive ? nil : state, host: nil))
        .accessibilityValue(TabPresence.value(workspace, tab.root.panes))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tabbar-\(ref)")
    }

    /// The title, then where the tab is (host, directory) and what it is on (branch, program or
    /// task), each once.
    static func tooltip(title: String, host: String?, directory: String?, context: String?) -> String {
        var lines = [title]
        let place = [host, directory].compactMap(\.self).joined(separator: " · ")
        if !place.isEmpty, place != title { lines.append(place) }
        if let context, !context.isEmpty, context != title, context != directory, context != "~" { lines.append(context) }
        return lines.joined(separator: "\n")
    }
}

/// A tab's panes into another tab of its host, as a split on the right (a tab dragged onto a
/// pane's edge does the same, on that edge).
struct MergeIntoTabMenu: View {
    let workspace: Workspace
    let tab: TabId
    @Environment(WindowModel.self) private var model

    var body: some View {
        let targets = model.moveTargets(in: workspace, besides: tab)
        if !targets.isEmpty {
            Menu("Merge Into Tab", systemImage: "rectangle.split.2x1") {
                ForEach(targets) { target in
                    Button(workspace.title(of: target)) { model.mergeTab(tab, in: workspace, into: target) }
                }
            }
            .accessibilityIdentifier("tab-merge-into")
        }
    }
}
