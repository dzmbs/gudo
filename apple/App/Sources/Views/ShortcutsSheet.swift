import DesignSystem
import SwiftUI

/// Every app shortcut on one page (⌘/), built from `WorkspaceAction` so it never drifts from what
/// the keys do. On iPad, holding ⌘ shows the system's own overlay too.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    /// One listed command and every key that runs it.
    struct Entry {
        let title: String
        let shortcuts: [KeyboardShortcut]

        init(_ action: WorkspaceAction) {
            title = action.title
            shortcuts = action.shortcuts
        }

        init(_ command: MenuCommand) {
            title = command.title
            shortcuts = [command.shortcut]
        }
    }

    /// Every command with a key, in the menus' groups: the app's actions and the menus' own.
    static var sections: [(title: String, entries: [Entry])] {
        let agents: [WorkspaceAction] = [.newAgent, .inbox, .jumpToWaitingAgent]
        let window = WorkspaceAction.windowActions.filter { !agents.contains($0) } + (WindowRequest.isSupported ? [.newWindow] : [])
        func menu(_ commands: [MenuCommand]) -> [Entry] {
            commands.filter(MenuCommand.available.contains).map(Entry.init)
        }
        return [
            ("Agents", agents.map(Entry.init)),
            ("Window", window.map(Entry.init) + menu([.closeWindow, .settings])),
            ("Tabs", ([.newTab, .newTabOnHost, .newProject] + WorkspaceAction.tabActions + WorkspaceAction.historyActions).map(Entry.init)
                + menu([.closeTab, .showAllRecentlyClosed])),
            ("Hosts", WorkspaceAction.hostActions.map(Entry.init)),
            ("Panes", ([.splitRight, .splitDown, .splitWithHost, .closePane] + WorkspaceAction.paneActions).map(Entry.init)
                + menu([.openToolInNewWindow])),
            ("Floating Windows", WorkspaceAction.floatActions.map(Entry.init)),
            ("Drawing", WorkspaceAction.drawActions.map(Entry.init)),
            ("Browser", WorkspaceAction.browserActions.map(Entry.init)),
            ("Font", WorkspaceAction.fontActions.map(Entry.init)),
            ("Git", menu([.runScript, .openPullRequest])),
        ]
    }

    /// One row per name, with every key that runs it (⌘K and ⇧⌘P are one Command Palette).
    static func rows(_ entries: [Entry]) -> [(title: String, keys: [[String]])] {
        var rows: [(title: String, keys: [[String]])] = []
        for entry in entries {
            let keys = entry.shortcuts.map(\.symbols)
            if let index = rows.firstIndex(where: { $0.title == entry.title }) {
                for key in keys where !rows[index].keys.contains(key) { rows[index].keys.append(key) }
            } else {
                rows.append((entry.title, keys))
            }
        }
        return rows
    }

    private func matches(_ entry: Entry) -> Bool {
        query.isEmpty || entry.title.localizedCaseInsensitiveContains(query)
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
            ForEach(Self.sections, id: \.title) { title, entries in
                let shown = Self.rows(entries.filter(matches))
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
