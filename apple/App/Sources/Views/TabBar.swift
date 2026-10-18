import DesignSystem
import PaneLayout
import SwiftUI

/// Horizontal tabs, after Ghostty's macOS native tab bar: equal-width tabs across the whole row,
/// each with a centered title (and the agent glyph when a pane reports one), ⌘N right-aligned,
/// a close button on hover at the leading edge, thin separators between unselected tabs, a slightly
/// lighter rounded pill for the selected tab, and + at the end. It sits on the terminal background
/// like Ghostty's transparent titlebar, so tabs and terminal read as one surface.
struct TabBar: View {
    let workspace: Workspace
    @Binding var style: TabStyle
    @Environment(AppModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @Namespace private var selection

    var body: some View {
        let tabs = workspace.session.tabs
        let activeIndex = tabs.firstIndex { $0.id == workspace.session.activeTabId }
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 {
                    // Ghostty/AppKit draw no separator next to the selected tab.
                    Rectangle()
                        .fill(Color.primary.opacity(index == activeIndex || index - 1 == activeIndex ? 0 : 0.14))
                        .frame(width: 1, height: 16)
                }
                TabChip(tab: tab, index: index, workspace: workspace, namespace: selection)
                    .frame(maxWidth: .infinity)
            }
            Button("New Tab", systemImage: "plus") { workspace.apply(.newTab) }
                .help("New Tab (⌘T)")
                .padding(.leading, DS.Space.xs)
            #if os(iOS)
            // iPad has no window toolbar in this layout; the pane controls live at the row's end.
            Menu("Pane", systemImage: "rectangle.split.2x1") {
                PaneMenuItems(workspace: workspace, model: model)
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("pane-menu")
            Button("Command Palette", systemImage: "command") { model.isPaletteShown = true }
            TabStyleToggle(style: $style)
            #endif
        }
        .buttonStyle(.bar)
        .labelStyle(.iconOnly)
        .padding(.horizontal, DS.Space.xs + 2)
        .frame(height: 34)
        .background(theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.splitDivider).frame(height: 1) }
        .animation(DS.Motion.snappy, value: workspace.session.activeTabId)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-bar")
    }
}

private struct TabChip: View {
    let tab: Tab
    let index: Int
    let workspace: Workspace
    let namespace: Namespace.ID
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        let isActive = tab.id == workspace.session.activeTabId
        let states = tab.root.panes.compactMap { model.paneStatus.state(of: $0.description) }
        let state = states.min { $0.urgency < $1.urgency }
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
                if let state {
                    StatusIndicator(state, size: 10)
                }
                Text(workspace.title(of: tab))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout.weight(isActive ? .medium : .regular))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, 40)

            HStack(spacing: 0) {
                Button("Close Tab", systemImage: "xmark") { workspace.apply(.closeTab(tab.id)) }
                    .font(.caption2.weight(.bold))
                    .frame(width: 22, height: 22)
                    .opacity(isHovered ? 1 : 0)
                    .accessibilityHidden(!isHovered)
                Spacer(minLength: 0)
                if index < 8 {
                    Text("⌘\(index + 1)")
                        .font(DS.Font.meta)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, DS.Space.s)
                }
            }
            .padding(.leading, 3)
        }
        .frame(height: 34)
        .contentShape(.rect)
        .onTapGesture { workspace.selectTab(tab.id) }
        .onHover { isHovered = $0 }
        .contextMenu { TabMenu(tab: tab, workspace: workspace) }
        .draggable(String(tab.id.rawValue))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first.flatMap(UInt64.init) else { return false }
            workspace.apply(.moveTab(TabId(raw), to: index))
            return true
        }
        .help(workspace.directory(of: tab) ?? workspace.title(of: tab))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(workspace.title(of: tab))
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tabbar-\(tab.id)")
    }
}
