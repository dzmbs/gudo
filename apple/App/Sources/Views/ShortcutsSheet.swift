import DesignSystem
import SwiftUI

/// Every app shortcut on one page (⌘/), built from `WorkspaceAction` so it never drifts from what
/// the keys do. On iPad, holding ⌘ shows the system's own overlay too.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var sections: [(String, [WorkspaceAction])] {
        let agents: [WorkspaceAction] = [.newAgent, .inbox, .jumpToWaitingAgent]
        return [
            ("Agents", agents),
            ("Window", WorkspaceAction.windowActions.filter { !agents.contains($0) } + (WindowRequest.isSupported ? [.newWindow] : [])),
            ("Tabs", [.newTab, .newTabOnHost] + WorkspaceAction.tabActions),
            ("Hosts", WorkspaceAction.hostActions),
            ("Panes", [.splitRight, .splitDown, .splitWithHost, .closePane] + WorkspaceAction.paneActions),
            ("Floating Windows", WorkspaceAction.floatActions),
            ("Drawing", WorkspaceAction.drawActions),
            ("Browser", WorkspaceAction.browserActions),
            ("Font", WorkspaceAction.fontActions),
        ]
    }

    /// One row per action name, with every key that runs it (⌘K and ⇧⌘P are one Command Palette).
    static func rows(_ actions: [WorkspaceAction]) -> [(title: String, keys: [[String]])] {
        var rows: [(title: String, keys: [[String]])] = []
        for action in actions {
            let keys = action.shortcuts.map(\.symbols)
            if let index = rows.firstIndex(where: { $0.title == action.title }) {
                for key in keys where !rows[index].keys.contains(key) { rows[index].keys.append(key) }
            } else {
                rows.append((action.title, keys))
            }
        }
        return rows
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
                let shown = Self.rows(actions.filter(matches))
                if !shown.isEmpty {
                    Section {
                        ForEach(shown, id: \.title) { row in
                            HStack {
                                Text(row.title)
                                Spacer()
                                ForEach(row.keys, id: \.self) { keys in
                                    ShortcutLabel(keys)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
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
