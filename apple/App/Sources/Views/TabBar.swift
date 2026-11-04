import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Equal-width horizontal tabs after Ghostty's macOS tab bar, every host's tabs in sidebar order.
struct TabBar: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Namespace private var selection
    /// After a close under the pointer, tabs keep their width until the pointer leaves the strip,
    /// so the next close button lands under it.
    @State private var isPointerInside = false
    @State private var frozenWidth: CGFloat?
    @State private var chipWidth: CGFloat = 0

    var body: some View {
        let active = model.destination == .terminal ? model.currentTab : nil
        HStack(spacing: 0) {
            // More tabs than the strip holds scroll instead of widening the window.
            ViewThatFits(in: .horizontal) {
                chips
                ScrollView(.horizontal, showsIndicators: false) { chips }
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
        .animation(DS.Motion.quick, value: active)
        .onHover { inside in
            isPointerInside = inside
            if !inside, frozenWidth != nil { withAnimation(DS.Motion.quick) { frozenWidth = nil } }
        }
        .onChange(of: model.groups.tabs.count) { old, new in
            if new < old, isPointerInside, chipWidth > 0 { frozenWidth = chipWidth }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-bar")
    }

    @ViewBuilder private var chips: some View {
        let groups = model.groups.groups
        let allTabs = model.groups.tabs
        let active = model.destination == .terminal ? model.currentTab : nil
        let activeIndex = active.flatMap { allTabs.firstIndex(of: $0) }
        HStack(spacing: 0) {
            // Tabs name their host only while the window holds more than one host.
            let isMultiHost = Set(allTabs.map(\.hostId)).count > 1
            ForEach(model.composites.ordered) { tab in
                MixedTabChip(tab: tab, isActive: WindowModel.mixedRef(tab.id) == active)
                    .frame(maxWidth: .infinity)
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
                    TabChip(tab: tab, ref: ref, group: group, isActive: ref == active, showsHost: isMultiHost, namespace: selection)
                        .frame(maxWidth: frozenWidth ?? .infinity)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { if frozenWidth == nil { chipWidth = $0 } }
                }
            }
            if frozenWidth != nil { Spacer(minLength: 0) }
        }
    }
}

private struct TabChip: View {
    let tab: Tab
    let ref: TabRef
    let group: HostGroup
    let isActive: Bool
    /// The window holds tabs from more than one host: name the host under the title.
    let showsHost: Bool
    let namespace: Namespace.ID
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
                    .matchedGeometryEffect(id: "selection", in: namespace)
                    .padding(.vertical, 3)
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
