import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Horizontal tabs, after Ghostty's macOS native tab bar: equal-width tabs across the whole row,
/// each with a centered title led by the program's mark (the agent glyph instead while an
/// a close button on hover at the leading edge, hairlines between unselected tabs, the selected tab
/// a pill of the theme's ink at 10 %, and + at the end. Inactive tabs are the same ink dimmed by
/// opacity (0.7, 0.85 on hover), so their glyph colours survive. It sits on the window's base,
/// the terminal's own background, so tabs and terminal read as one surface.
///
/// Every host's tabs share the strip in the sidebar's order; with more than one host, each run of
/// tabs carries its host as a second line (status UX §3.2); a single-host window shows no host.
struct TabBar: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Namespace private var selection

    var body: some View {
        let groups = model.groups.groups
        let all = model.groups.tabs
        let active = model.destination == .terminal ? model.currentTab : nil
        let activeIndex = active.flatMap { all.firstIndex(of: $0) }
        HStack(spacing: 0) {
            // Status UX §3.2: no host on a tab while the window is single-host; with tabs from
            // more than one host, each tab gets the host's name as a second line.
            let mixed = Set(all.map(\.hostId)).count > 1
            ForEach(groups) { group in
                ForEach(group.tabs) { tab in
                    let ref = group.ref(tab.id)
                    let index = all.firstIndex(of: ref) ?? 0
                    if index > 0 {
                        // Ghostty/AppKit draw no separator next to the selected tab.
                        Hairline(.vertical, style: DS.Palette.separator)
                            .frame(height: 16)
                            .opacity(index == activeIndex || index - 1 == activeIndex ? 0 : 1)
                    }
                    TabChip(tab: tab, ref: ref, group: group, isActive: ref == active, showsHost: mixed, namespace: selection)
                        .frame(maxWidth: .infinity)
                }
            }
            NewTabButton(workspace: workspace)
                .padding(.leading, DS.Space.xs)
        }
        .buttonStyle(.bar)
        .labelStyle(.iconOnly)
        .padding(.horizontal, DS.Space.xs + 2)
        .frame(height: 34)
        .background(DS.Palette.base)
        .overlay(alignment: .bottom) { Hairline(style: DS.Palette.separator) }
        .animation(DS.Motion.quick, value: active)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-bar")
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
                // §3.4: the program's mark; the agent glyph instead on an unfocused tab.
                TabLeadingMark(program: program, state: isActive ? nil : state)
                VStack(spacing: 0) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsHost {
                        Text(group.name)
                            .font(DS.Font.meta)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .font(DS.Font.tabTitle)
            .foregroundStyle(.primary)
            .opacity((isActive ? 1 : isHovered ? DS.Opacity.inactiveHover : DS.Opacity.inactive) * (group.isLocal || group.status.isLive ? 1 : 0.6))
            .padding(.horizontal, 40)

            HStack(spacing: 0) {
                Button("Close Tab", systemImage: "xmark") { workspace?.apply(.closeTab(tab.id)) }
                    .font(.caption2.weight(.bold))
                    .frame(width: 22, height: 22)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                    .help("Close Tab (⌘W)")
                Spacer(minLength: 0)
                if CommandKeyState.shared.held, let number = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(number)")
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, DS.Space.s)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 3)
            .animation(DS.Motion.quick, value: CommandKeyState.shared.held)
        }
        .frame(height: 34)
        .contentShape(.rect)
        .onTapGesture { model.focus(ref) }
        .onHover { hovering in withAnimation(DS.Motion.hover) { isHovered = hovering } }
        .contextMenu {
            if let workspace {
                Button("Rename…", systemImage: "pencil") {
                    model.focus(ref)
                    workspace.renamingTab = tab.id
                }
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openInNewWindow(ref) }
                Button("Close Tab", systemImage: "xmark", role: .destructive) { workspace.apply(.closeTab(tab.id)) }
            }
        }
        .tabDrag(ref, model: model)
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, let slash = item.lastIndex(of: "/"),
                  String(item[..<slash]) == group.id, let raw = UInt64(item[item.index(after: slash)...]),
                  let index = group.tabs.firstIndex(where: { $0.id == tab.id })
            else { return false }
            workspace?.apply(.moveTab(TabId(raw), to: index))
            return true
        }
        .help([group.isLocal ? nil : group.name, workspace?.directory(of: tab) ?? title].compactMap(\.self).joined(separator: " · "))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TabLeadingMark.label(title: title, program: program, state: isActive ? nil : state, host: nil))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tabbar-\(ref)")
    }
}
