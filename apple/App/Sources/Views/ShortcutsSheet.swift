import DesignSystem
import SwiftUI

/// Every app shortcut on one page (⌘/), built from `WorkspaceAction` so it never drifts from what
/// too.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var sections: [(String, [WorkspaceAction])] {
        [
            ("Window", WorkspaceAction.windowActions + [.newWindow]),
            ("Tabs", [.newTab, .newTabOnHost] + WorkspaceAction.tabActions),
            ("Panes", [.splitRight, .splitDown, .splitWithHost, .closePane] + WorkspaceAction.paneActions),
            ("Drawing", WorkspaceAction.drawActions),
        ]
    }

    private func matches(_ action: WorkspaceAction) -> Bool {
        query.isEmpty || action.title.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections, id: \.0) { title, actions in
                    let shown = actions.filter(matches)
                    if !shown.isEmpty {
                        Section(title) {
                            ForEach(shown, id: \.self) { action in
                                HStack {
                                    Text(action.title)
                                    Spacer()
                                    ShortcutLabel(action.shortcut.symbols)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .chromeRows()
                    }
                }
            }
            .chromeGrouped()
            .searchable(text: $query, prompt: "Search Shortcuts")
            .navigationTitle("Keyboard Shortcuts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 520)
        #endif
        .accessibilityIdentifier("shortcuts-sheet")
    }
}
