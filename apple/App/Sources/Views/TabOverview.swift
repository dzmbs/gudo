#if os(iOS)
import DesignSystem
import SwiftUI

/// Compact width (iPhone, a narrow iPad window): the sidebar's projects, tabs and agents on a
/// page of their own, opened from the title menu's Show All. Showing a tab closes it.
struct TabOverview: View {
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WorkspaceSidebar(showsDestinations: false)
                .environment(\.sidebarListStyle, .grouped)
                .navigationTitle("Tabs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("tab-overview-done")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !model.isSelectingTabs, model.groups.tabs.count > 1 {
                            Button("Select") { withAnimation(DS.Motion.snappy) { model.isSelectingTabs = true } }
                                .accessibilityIdentifier("tab-overview-select")
                        }
                        NewTabButton(workspace: workspace)
                    }
                }
                .chromeBarBackground(.sidebar)
        }
        .chromeBackground(DS.Palette.groupedPage)
        .accessibilityIdentifier("tab-overview")
        .onDisappear { model.endTabSelection() }
    }
}
#endif
