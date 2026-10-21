import DesignSystem
import SwiftUI

/// setting, by its title, its Ghostty config key ("cursor-style") and a few other words people use
/// for it. Every word typed must match. A result jumps to its row and lights it for a moment.
nonisolated struct SettingsEntry: Identifiable, Hashable, Sendable {
    /// The row's anchor (`settingAnchor`).
    var id: String
    var title: String
    /// The Ghostty key the row mirrors, if any.
    var key: String?
    var section: SettingsSection
    /// Other words for it.
    var synonyms: [String] = []

    /// Where it sits: "Terminal › Cursor" on the Mac, "Cursor" in the iOS form.
    var breadcrumb: String {
        #if os(macOS)
        section.pane.title == section.title ? section.title : "\(section.pane.title) › \(section.title)"
        #else
        section.title
        #endif
    }
}

/// The groups of Settings (the iOS form's sections; on the Mac, inside its panes).
nonisolated enum SettingsSection: String, Sendable {
    case appearance, font, cursor, splits, keyboard, passwords, voice, notifications, bell, agents, git, about

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .font: "Font"
        case .cursor: "Cursor"
        case .splits: "Splits"
        case .keyboard: "Keyboard"
        case .passwords: "Passwords"
        case .voice: "Voice"
        case .notifications: "Notifications"
        case .bell: "Bell"
        case .agents: "Agent Usage"
        case .git: "Git"
        case .about: "About"
        }
    }

    #if os(macOS)
    var pane: SettingsPane {
        switch self {
        case .appearance: .appearance
        case .font, .cursor, .splits, .passwords: .terminal
        case .keyboard, .voice: .keyboard
        case .notifications, .bell: .notifications
        case .agents: .agents
        case .git: .git
        case .about: .about
        }
    }
    #endif
}

enum SettingsIndex {
    static let all: [SettingsEntry] = {
        var entries: [SettingsEntry] = [
            .init(id: "theme", title: "Theme", key: "theme", section: .appearance, synonyms: ["color", "colour", "scheme", "palette"]),
            .init(id: "window-theme", title: "Window", key: "window-theme", section: .appearance, synonyms: ["light", "dark", "mode", "appearance", "system"]),
            .init(id: "pane-style", title: "Panes", key: "pane-style", section: .appearance, synonyms: ["padding", "compact", "spacious"]),
            .init(id: "title-from-shell", title: "Tab Title from Shell", key: "title-from-shell", section: .appearance, synonyms: ["tab", "name", "osc"]),
            .init(id: "font-family", title: "Font Family", key: "font-family", section: .font, synonyms: ["typeface", "jetbrains", "mono"]),
            .init(id: "font-size", title: "Font Size", key: "font-size", section: .font, synonyms: ["text", "zoom", "bigger", "smaller"]),
            .init(id: "cursor-style", title: "Cursor Style", key: "cursor-style", section: .cursor, synonyms: ["block", "bar", "underline", "caret"]),
            .init(id: "cursor-style-blink", title: "Cursor Blink", key: "cursor-style-blink", section: .cursor, synonyms: ["blinking", "caret"]),
            .init(id: "unfocused-split-opacity", title: "Unfocused Pane Opacity", key: "unfocused-split-opacity", section: .splits, synonyms: ["dim", "split", "fade"]),
            .init(id: "resize-overlay", title: "Size Overlay", key: "resize-overlay", section: .splits, synonyms: ["resize", "columns", "rows"]),
            .init(id: "macos-option-as-alt", title: "Option Sends Meta", key: "macos-option-as-alt", section: .keyboard, synonyms: ["alt", "meta", "option", "esc"]),
            .init(id: "saved-passwords", title: "Saved Passwords", section: .passwords, synonyms: ["sudo", "ssh", "askpass", "keychain", "forget"]),
            .init(id: "dictation", title: "Dictation", section: .voice, synonyms: ["voice", "speech", "microphone", "language"]),
            .init(id: "notify-approvals", title: "Approval Requests", section: .notifications, synonyms: ["notification", "approve", "deny", "push"]),
            .init(id: "notify-blocked", title: "Agent Waiting", section: .notifications, synonyms: ["notification", "question", "blocked"]),
            .init(id: "notify-done", title: "Agent Finished", section: .notifications, synonyms: ["notification", "done", "complete"]),
            .init(id: "notify-failed", title: "Agent Failed", section: .notifications, synonyms: ["notification", "error"]),
            .init(id: "notify-commands", title: "Long Commands", section: .notifications, synonyms: ["notification", "command", "finished"]),
            .init(id: "notify-background", title: "Only When the App Is in the Background", section: .notifications, synonyms: ["notification", "foreground"]),
            .init(id: "bell-features", title: "Flash Border on Bell", key: "bell-features", section: .bell, synonyms: ["bell", "beep", "alert"]),
            .init(id: "usage-api-fallback", title: "Check Usage with Your Claude and Codex Sign-In", section: .agents, synonyms: ["usage", "limits", "plan", "meter", "quota"]),
            .init(id: "merge-strategy", title: "Merge Pull Requests With", section: .git, synonyms: ["pr", "squash", "rebase", "merge"]),
            .init(id: "auto-delete", title: "Delete Merged Worktrees", section: .git, synonyms: ["worktree", "cleanup", "branch"]),
            .init(id: "git-scripts", title: "Scripts", section: .git, synonyms: ["run", "command", "⌘r"]),
            .init(id: "version", title: "Version", section: .about, synonyms: ["build", "about"]),
            .init(id: "acknowledgements", title: "Acknowledgements", section: .about, synonyms: ["licenses", "licences", "credits", "open source"]),
        ]
        #if os(iOS)
        entries += [
            .init(id: "tab-bar", title: "Tab Bar When the Sidebar Is Hidden", section: .appearance, synonyms: ["tabs", "strip"]),
            .init(id: "ascii-keyboard", title: "ASCII Keyboard", section: .keyboard, synonyms: ["keyboard", "autocorrect"]),
            .init(id: "hardware-key-bar", title: "With a Hardware Keyboard", section: .keyboard, synonyms: ["key bar", "esc", "pill", "magic keyboard"]),
            .init(id: "key-bar-profiles", title: "Key Bar Profiles", section: .keyboard, synonyms: ["key bar", "keys", "ctrl"]),
        ]
        #else
        entries.append(.init(id: "tab-bar", title: "Tab Bar When the Sidebar Is Hidden", section: .appearance, synonyms: ["tabs", "strip"]))
        #endif
        return entries
    }()

    /// The entries every word of `query` matches (title, key, synonyms, section), best first: a
    /// key or title that starts with the query, then the rest in Settings order.
    static func search(_ query: String, in entries: [SettingsEntry] = all) -> [SettingsEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        let matches = entries.enumerated().filter { _, entry in
            let haystack = ([entry.title, entry.key ?? "", entry.section.title] + entry.synonyms).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        func rank(_ entry: SettingsEntry) -> Int {
            if entry.key?.lowercased() == needle { return 0 }
            if entry.key?.lowercased().hasPrefix(needle) == true || entry.title.lowercased().hasPrefix(needle) { return 1 }
            if entry.title.lowercased().contains(needle) { return 2 }
            return 3
        }
        return matches.sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

// MARK: - Anchors and the highlight

extension EnvironmentValues {
    /// The setting a search result just jumped to: its row lights up for a moment.
    @Entry var settingsHighlight: String?
}

private struct SettingAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        let lit = highlight == id
        content
            .id(id)
            // The row's own surface (as `chromeRows()`), with the accent washed over it while lit.
            .listRowBackground(
                Rectangle().fill(DS.Palette.groupedRow)
                    .overlay(Rectangle().fill(DS.Palette.accent.opacity(lit ? 0.18 : 0)))
                    .animation(DS.Motion.overlay, value: lit))
    }
}

extension View {
    /// Marks a Settings row a search result can jump to (`SettingsIndex` entry `id`).
    func settingAnchor(_ id: String) -> some View {
        modifier(SettingAnchor(id: id))
    }
}

/// One search result: the title, the Ghostty key in SF Mono, and where it lives.
struct SettingsResultRow: View {
    let entry: SettingsEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .foregroundStyle(.primary)
                if let key = entry.key {
                    Text(key)
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: DS.Space.s)
            Text(entry.breadcrumb)
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-result-\(entry.id)")
    }
}

/// The iOS results list: picking one closes the search and jumps to the row.
struct SettingsResults: View {
    let query: String
    let pick: (SettingsEntry) -> Void
    @Environment(\.dismissSearch) private var dismissSearch

    var body: some View {
        let results = SettingsIndex.search(query)
        List {
            ForEach(results) { entry in
                Button {
                    dismissSearch()
                    pick(entry)
                } label: {
                    SettingsResultRow(entry: entry)
                }
                .buttonStyle(.plain)
                .chromeRows()
            }
        }
        .overlay { if results.isEmpty { SettingsNoResults(query: query) } }
    }
}

/// "No settings match": the one-line empty state.
struct SettingsNoResults: View {
    let query: String

    var body: some View {
        ContentUnavailableView.search(text: query)
    }
}
