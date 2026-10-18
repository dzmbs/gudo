import PaneLayout
import SwiftUI

/// Vertical tabs: one row per tab, drag to reorder.
struct TabSidebar: View {
    let workspace: Workspace

    var body: some View {
        let selection = Binding(
            get: { workspace.session.activeTabId },
            set: { id in if let id { workspace.selectTab(id) } })
        List(selection: selection) {
            ForEach(workspace.session.tabs) { tab in
                TabRow(tab: tab, title: workspace.title(of: tab))
                    .tag(tab.id)
                    .contextMenu { TabMenu(tab: tab, workspace: workspace) }
                    .accessibilityIdentifier("sidebar-\(tab.id)")
            }
            .onMove { source, destination in
                guard let from = source.first else { return }
                // `destination` is an insertion point in the original order.
                workspace.apply(.moveTab(workspace.session.tabs[from].id, to: destination > from ? destination - 1 : destination))
            }
        }
        .navigationTitle("Tabs")
        .toolbar {
            ToolbarItem {
                Button("New Tab", systemImage: "plus") { workspace.apply(.newTab) }
            }
        }
    }
}

private struct TabRow: View {
    let tab: Tab
    let title: String

    var body: some View {
        let count = tab.root.panes.count
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if count > 1 {
                    Text(tab.zoomed == nil ? "\(count) panes" : "\(count) panes · zoomed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: count > 1 ? "rectangle.split.2x1" : "terminal")
        }
    }
}

/// Horizontal tabs above the panes.
struct TabBar: View {
    let workspace: Workspace
    @Binding var style: TabStyle

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(Array(workspace.session.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabChip(tab: tab, index: index, workspace: workspace)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            Button("New Tab", systemImage: "plus") { workspace.apply(.newTab) }
                .labelStyle(.iconOnly)
            PaneMenu(workspace: workspace)
                .labelStyle(.iconOnly)
            TabStyleToggle(style: $style)
                .labelStyle(.iconOnly)
                .padding(.trailing, 8)
        }
        .buttonStyle(.borderless)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabChip: View {
    let tab: Tab
    let index: Int
    let workspace: Workspace

    var body: some View {
        let isActive = tab.id == workspace.session.activeTabId
        HStack(spacing: 4) {
            Button { workspace.selectTab(tab.id) } label: {
                HStack(spacing: 6) {
                    if tab.root.panes.count > 1 { Image(systemName: "rectangle.split.2x1").imageScale(.small) }
                    Text(workspace.title(of: tab)).lineLimit(1)
                }
                .padding(.leading, 12)
                .padding(.trailing, isActive ? 0 : 12)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isActive {
                Button("Close Tab", systemImage: "xmark") { workspace.apply(.closeTab(tab.id)) }
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
            }
        }
        .font(.callout)
        .foregroundStyle(isActive ? .primary : .secondary)
        .background(isActive ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(.fill.quaternary), in: .capsule)
        .contextMenu { TabMenu(tab: tab, workspace: workspace) }
        .draggable(String(tab.id.rawValue))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first.flatMap(UInt64.init) else { return false }
            workspace.apply(.moveTab(TabId(raw), to: index))
            return true
        }
        .accessibilityIdentifier("tabbar-\(tab.id)")
    }
}

/// iPhone (compact width): one pane full screen under a 32 pt top bar whose title opens the tab
/// switcher (04-mobile-ux C3).
struct CompactWorkspaceView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                tabSwitcher
                Spacer()
                if let tab = workspace.session.activeTab, tab.root.panes.count > 1 {
                    paneSwitcher(tab)
                }
                Button("New Tab", systemImage: "plus") { workspace.apply(.newTab) }
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            ActiveTabView(workspace: workspace, compact: true)
        }
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
            HStack(spacing: 4) {
                Text(workspace.session.activeTab.map(workspace.title(of:)) ?? "No Tabs")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
        .accessibilityIdentifier("tab-switcher")
    }

    private func paneSwitcher(_ tab: Tab) -> some View {
        Menu {
            Picker("Pane", selection: Binding(get: { tab.focused }, set: { workspace.apply(.focus($0)) })) {
                ForEach(Array(tab.root.panes.enumerated()), id: \.element) { index, pane in
                    Text("Pane \(index + 1)").tag(pane)
                }
            }
        } label: {
            Label("Panes", systemImage: "rectangle.split.2x1")
                .labelStyle(.iconOnly)
        }
    }
}
