import DesignSystem
import SwiftUI

/// Every app shortcut on one page (⌘/), built from `WorkspaceAction` so it never drifts from what
/// too.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var sections: [(String, [WorkspaceAction])] {
        let agents: [WorkspaceAction] = [.newAgent, .inbox, .jumpToWaitingAgent]
        return [
            ("Agents", agents),
            ("Window", WorkspaceAction.windowActions.filter { !agents.contains($0) } + [.newWindow]),
            ("Tabs", [.newTab, .newTabOnHost] + WorkspaceAction.tabActions),
            ("Hosts", WorkspaceAction.hostActions),
            ("Panes", [.splitRight, .splitDown, .splitWithHost, .closePane] + WorkspaceAction.paneActions),
            ("Floating Windows", WorkspaceAction.floatActions),
            ("Drawing", WorkspaceAction.drawActions),
        ]
    }

    private func matches(_ action: WorkspaceAction) -> Bool {
        query.isEmpty || action.title.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        #if os(macOS)
        SheetScaffold("Keyboard Shortcuts", cancel: SheetAction("Done") { dismiss() }) {
            VStack(spacing: DS.Space.s) {
                FilterField(text: $query, prompt: "Search Shortcuts")
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.top, DS.Space.s)
                list
            }
        }
        .frame(width: 520, height: 600)
        .accessibilityIdentifier("shortcuts-sheet")
        #else
        NavigationStack {
            list
                .searchable(text: $query, prompt: "Search Shortcuts")
                .navigationTitle("Keyboard Shortcuts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .accessibilityIdentifier("shortcuts-sheet")
        #endif
    }

    private var list: some View {
        GroupedList {
            ForEach(sections, id: \.0) { title, actions in
                let shown = actions.filter(matches)
                if !shown.isEmpty {
                    Section {
                        ForEach(shown, id: \.self) { action in
                            HStack {
                                Text(action.title)
                                Spacer()
                                ShortcutLabel(action.shortcut.symbols)
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        SectionTitle(title)
                    }
                    .chromeRows()
                }
            }
        }
    }
}
