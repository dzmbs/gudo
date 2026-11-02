import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
#if os(macOS)
import AppKit
#else
import GameController
#endif

/// The modifiers held as a row is clicked or tapped: ⌘ toggles it in the selection, ⇧ extends
/// it. The Mac asks AppKit; an iPad asks its hardware keyboard.
enum ClickModifiers {
    static var current: EventModifiers {
        var modifiers: EventModifiers = []
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        #else
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return [] }
        func held(_ codes: GCKeyCode...) -> Bool { codes.contains { keys.button(forKeyCode: $0)?.isPressed == true } }
        if held(.leftGUI, .rightGUI) { modifiers.insert(.command) }
        if held(.leftShift, .rightShift) { modifiers.insert(.shift) }
        #endif
        return modifiers
    }
}

// The sidebar's tab-history rows, the selection bar, and the History menu's items
// (docs/APP-ARCHITECTURE.md §25, docs/DESIGN.md "Sidebar").

/// "Restore 6 Tabs": the tabs a launch under "A New Terminal" kept out of sight, one tap away.
/// Shown while there is something to restore; gone when used or dismissed.
struct RestoreTabsRow: View {
    let count: Int
    @Environment(WindowModel.self) private var model

    var body: some View {
        SidebarNoticeRow(
            systemImage: "arrow.counterclockwise",
            title: count == 1 ? "Restore 1 Tab" : "Restore \(count) Tabs",
            detail: "Your tabs from last time are still running",
            help: "History ▸ Reopen Previous Tabs does the same",
            identifier: "restore-tabs"
        ) {
            model.restoreHiddenTabs()
        } dismiss: {
            withAnimation(DS.Motion.snappy) { model.groups.restoreDismissed = true }
        }
    }
}

/// "Close 6 Idle Tabs": tabs at a prompt, untouched for days. Never acts on its own; what it
/// closes goes to Recently Closed.
struct IdleTabsRow: View {
    let count: Int
    @Environment(WindowModel.self) private var model

    var body: some View {
        SidebarNoticeRow(
            systemImage: "moon.zzz",
            title: count == 1 ? "Close 1 Idle Tab" : "Close \(count) Idle Tabs",
            detail: "At a prompt, untouched for \(IdleTabRule.days) days",
            help: "They go to History ▸ Recently Closed",
            identifier: "idle-tabs"
        ) {
            model.closeIdleTabs()
        } dismiss: {
            model.dismissIdleTabs()
        }
    }
}

/// A quiet one-line offer at the top of the sidebar, in the project suggestion's voice: a
/// glyph, the verb in secondary ink, the rest in tertiary, a dismiss ×. No card: it sits among
/// the rows and leaves the tabs the attention. What it means in full is its tooltip.
private struct SidebarNoticeRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let help: String
    let identifier: String
    let action: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.gap10) {
            Button(action: action) {
                HStack(spacing: DS.Space.gap10) {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 16)
                    Text(title)
                        .font(DS.Font.sidebarSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("\(detail). \(help)")
            .accessibilityHint(detail)
            Button("Not Now", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.sidebarDismiss)
                .font(.caption2)
                .foregroundStyle(DS.Palette.textTertiary)
                .help("Not Now")
                .accessibilityIdentifier("\(identifier)-dismiss")
        }
        .sidebarRow(selected: false)
        .padding(.top, DS.Space.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Under the sidebar while tabs are selected: how many, and what can be done to all of them.
struct TabSelectionBar: View {
    @Environment(WindowModel.self) private var model

    var body: some View {
        let count = model.tabSelection.selected.count
        HStack(spacing: DS.Space.m) {
            Text(count == 0 ? "Select Tabs" : count == 1 ? "1 Tab" : "\(count) Tabs")
                .font(DS.Font.sidebarSubtitle.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary)
                .contentTransition(.numericText())
            Spacer(minLength: DS.Space.xs)
            Menu {
                TabSelectionMenuItems(model: model)
            } label: {
                Label("Actions for Selected Tabs", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.textSecondary)
            .disabled(count == 0)
            .help("Actions for the selected tabs")
            Button("Done") { withAnimation(DS.Motion.snappy) { model.endTabSelection() } }
                .buttonStyle(.quietProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(DS.Palette.sidebar)
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-selection-bar")
    }
}

/// What can be done to the selected tabs (a selected row's context menu, the selection bar).
struct TabSelectionMenuItems: View {
    let model: WindowModel

    var body: some View {
        let refs = model.selectedTabs
        let projects = model.projects
        Button("Close \(refs.count) Tabs", systemImage: "xmark", role: .destructive) { model.requestCloseSelectedTabs() }
        Divider()
        Button("New Project from \(refs.count) Tabs", systemImage: "folder.badge.plus") { model.newProjectFromSelectedTabs() }
        if !projects.isEmpty {
            Menu("Move to Project", systemImage: "folder") {
                ForEach(projects) { project in
                    Button(project.name) { model.moveSelectedTabs(toProject: project.id) }
                }
            }
        }
        Divider()
        Button("Select All Tabs", systemImage: "checklist") { model.selectAllTabs() }
        Button("Deselect All") { withAnimation(DS.Motion.snappy) { model.endTabSelection() } }
    }
}

/// History ▸ Recently Closed, the compact switcher's submenu: the newest first, each with
/// where it was and when it closed.
struct RecentlyClosedMenuItems: View {
    let model: WindowModel
    var limit = RecentlyClosed.limit

    var body: some View {
        let tabs = Array(model.recentlyClosed.tabs.prefix(limit))
        if tabs.isEmpty {
            Text("No Recently Closed Tabs")
        } else {
            ForEach(tabs) { entry in
                Button {
                    model.reopenClosed(entry.id)
                } label: {
                    Label {
                        Text(entry.title)
                        Text(entry.subtitle())
                    } icon: {
                        Image(systemName: entry.agent == nil ? "terminal" : "sparkle")
                    }
                }
            }
        }
    }
}

/// The History menu's own items, shared by the menu bar and the compact switcher.
struct HistoryMenuItems: View {
    let model: WindowModel?

    var body: some View {
        Button(WorkspaceAction.reopenClosedTab.title) { model?.reopenLastClosed() }
            .keyboardShortcut(WorkspaceAction.reopenClosedTab.shortcut)
            .disabled(model?.recentlyClosed.tabs.isEmpty ?? true)
        let hidden = model?.groups.restorableTabs.count ?? 0
        Button(hidden > 0 ? "Reopen Previous Tabs (\(hidden))" : "Reopen Previous Tabs") { model?.restoreHiddenTabs() }
            .disabled(hidden == 0)
        if let model, !model.idleTabs.isEmpty {
            Button("Close \(model.idleTabs.count) Idle Tabs") { model.closeIdleTabs() }
        }
        Divider()
        if let model {
            Menu("Recently Closed") {
                RecentlyClosedMenuItems(model: model)
                if !model.recentlyClosed.tabs.isEmpty {
                    Divider()
                    Button("Clear Recently Closed") { model.recentlyClosed.removeAll() }
                }
            }
        }
        // Safari's Show All History (⌘Y): the same list, searchable.
        Button("Show All Recently Closed…") { model?.showRecentlyClosed() }
            .keyboardShortcut("y")
            .disabled(model?.recentlyClosed.tabs.isEmpty ?? true)
    }
}

/// The one question a bulk close asks when work runs in a selected tab.
struct BulkCloseConfirmation: ViewModifier {
    let model: WindowModel

    func body(content: Content) -> some View {
        let refs = model.pendingBulkClose ?? []
        let busy = refs.filter { model.tabActivity($0).isBusy }.count
        content.alert(
            "Close \(refs.count) Tabs?",
            isPresented: Binding(get: { model.pendingBulkClose != nil }, set: { if !$0 { model.pendingBulkClose = nil } })
        ) {
            Button("Close \(refs.count) Tabs", role: .destructive) {
                model.pendingBulkClose = nil
                model.closeSelectedTabs(refs)
            }
            Button("Cancel", role: .cancel) { model.pendingBulkClose = nil }
        } message: {
            Text(busy == 1
                ? "An agent or command is running in one of them. Closing ends it; the tab can be reopened from History."
                : "Agents or commands are running in \(busy) of them. Closing ends them; the tabs can be reopened from History.")
        }
    }
}

#if os(iOS)
/// The compact switcher's Select mode: every tab in sidebar order in a list that selects
/// several, and what to do with them.
struct CompactTabSelection: View {
    @Environment(WindowModel.self) private var model
    @State private var selection: Set<TabRef> = []

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                ForEach(model.groups.tabs, id: \.self) { ref in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title(ofTab: ref)).font(DS.Font.rowTitle)
                        Text([model.groupName(ref.hostId), model.groups.project(of: ref)?.name].compactMap(\.self).joined(separator: " · "))
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    .tag(ref)
                }
                .chromeRows()
            }
            .chromeGrouped()
            .environment(\.editMode, .constant(.active))
            .navigationTitle(selection.isEmpty ? "Select Tabs" : selection.count == 1 ? "1 Tab" : "\(selection.count) Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selection.count == model.groups.tabs.count ? "Deselect All" : "Select All") {
                        selection = selection.count == model.groups.tabs.count ? [] : Set(model.groups.tabs)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.endTabSelection() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        TabSelectionMenuItems(model: model)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .disabled(selection.isEmpty)
                    Spacer()
                    Button("Close", systemImage: "xmark", role: .destructive) { model.requestCloseSelectedTabs() }
                        .disabled(selection.isEmpty)
                }
            }
            .onChange(of: selection, initial: true) { _, refs in
                var next = TabSelection()
                next.selectAll(model.groups.tabs.filter { refs.contains($0) })
                model.tabSelection = next
            }
            .modifier(BulkCloseConfirmation(model: model))
        }
    }
}
#endif

/// The × on a sidebar notice: a small glyph with a finger-sized target that overhangs the row
/// rather than making it taller.
struct SidebarDismissButtonStyle: ButtonStyle {
    #if os(iOS)
    private static let target: CGFloat = 44
    #else
    private static let target: CGFloat = 24
    #endif

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .frame(minWidth: Self.target, minHeight: Self.target)
            .contentShape(.rect)
            .padding(.vertical, -Self.target / 4)
    }
}

extension ButtonStyle where Self == SidebarDismissButtonStyle {
    static var sidebarDismiss: SidebarDismissButtonStyle { SidebarDismissButtonStyle() }
}
