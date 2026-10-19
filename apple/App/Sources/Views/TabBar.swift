import DesignSystem
import HostKit
import PaneLayout
import SwiftUI

/// Horizontal tabs, after Ghostty's macOS native tab bar: equal-width tabs across the whole row,
/// each with a centered title led by the program's mark (the agent glyph instead while an
/// unfocused tab's pane reports one), ⌘N right-aligned,
/// a close button on hover at the leading edge, thin separators between unselected tabs, a slightly
/// lighter rounded pill for the selected tab, and + at the end. It sits on the terminal background
/// like Ghostty's transparent titlebar, so tabs and terminal read as one surface.
///
/// Every host's tabs share the strip in the sidebar's order; with more than one host, each run of
/// tabs carries its host as a second line (status UX §3.2); a single-host window shows no host.
struct TabBar: View {
    let workspace: Workspace
    @Binding var style: TabStyle
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
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
                        Rectangle()
                            .fill(Color.primary.opacity(index == activeIndex || index - 1 == activeIndex ? 0 : 0.14))
                            .frame(width: 1, height: 16)
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
        .background(theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.splitDivider).frame(height: 1) }
        .animation(DS.Motion.snappy, value: active)
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
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.11))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                    .matchedGeometryEffect(id: "selection", in: namespace)
                    .padding(.vertical, 3)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.05))
                    .padding(.vertical, 3)
            }

            HStack(spacing: DS.Space.xs + 2) {
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
            .font(.callout.weight(isActive ? .medium : .regular))
            .foregroundStyle(isActive ? .primary : .secondary)
            .opacity(group.isLocal || group.status.isLive ? 1 : 0.6)
            .padding(.horizontal, 40)

            HStack(spacing: 0) {
                Button("Close Tab", systemImage: "xmark") { workspace?.apply(.closeTab(tab.id)) }
                    .font(.caption2.weight(.bold))
                    .frame(width: 22, height: 22)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                Spacer(minLength: 0)
                if let number = model.groups.shortcutNumber(of: ref) {
                    Text("⌘\(number)")
                        .font(DS.Font.meta)
                        .foregroundStyle(.tertiary)
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
