import DesignSystem
import SwiftUI

/// Settings search: one flat index of every setting, by its title, its Ghostty config key
/// ("cursor-style") and a few other words people use for it. Every word typed must match.
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
    case appearance, tabs, font, cursor, splits, links, browser, keyboard, appLock, passwords, sshKeys, voice, notifications, bell, accounts, agentTools, git, network, devices, thisMac, about

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .tabs: "Tabs"
        case .font: "Font"
        case .cursor: "Cursor"
        case .splits: "Splits"
        case .links: "Links"
        case .browser: "Browser"
        case .keyboard: "Keyboard"
        case .appLock: "App Lock"
        case .passwords: "Passwords"
        case .sshKeys: "SSH"
        case .voice: "Voice"
        case .notifications: "Notifications"
        case .bell: "Bell"
        case .accounts: "Accounts"
        case .agentTools: "Agent Tools"
        case .git: "Git"
        case .network: "Network"
        case .devices: "Devices"
        case .thisMac: "This Mac"
        case .about: "About"
        }
    }

    #if os(macOS)
    var pane: SettingsPane {
        switch self {
        case .appearance, .tabs: .appearance
        case .font, .cursor, .splits, .links: .terminal
        case .appLock, .passwords, .sshKeys: .privacy
        case .browser: .browser
        case .keyboard, .voice: .keyboard
        case .notifications, .bell: .notifications
        case .accounts, .agentTools: .agents
        case .git: .git
        case .network: .network
        case .devices: .devices
        case .thisMac: .thisMac
        case .about: .about
        }
    }
    #endif
}

enum SettingsIndex {
    static let all: [SettingsEntry] = {
        var entries: [SettingsEntry] = [
            .init(id: "theme", title: "Theme", key: "theme", section: .appearance, synonyms: ["color", "colour", "scheme", "palette"]),
            .init(id: "window-theme", title: "Window Matches Theme", key: "window-theme", section: .appearance, synonyms: ["window", "light", "dark", "mode", "appearance", "system", "sidebar", "chrome"]),
            .init(id: "theme-pair", title: "Follow Light and Dark Mode", key: "theme", section: .appearance, synonyms: ["light theme", "dark theme", "automatic", "system appearance", "pair"]),
            .init(id: "pane-style", title: "Panes", key: "pane-style", section: .appearance, synonyms: ["padding", "compact", "spacious"]),
            .init(id: "title-from-shell", title: "Tab Title from Shell", key: "title-from-shell", section: .appearance, synonyms: ["tab", "name", "osc"]),
            .init(id: "launch-tabs", title: "Opens With", section: .tabs, synonyms: ["launch", "startup", "restore", "previous tabs", "new terminal", "session", "reopen", "start"]),
            .init(id: "font-family", title: "Font Family", key: "font-family", section: .font, synonyms: ["typeface", "jetbrains", "mono"]),
            .init(id: "font-size", title: "Font Size", key: "font-size", section: .font, synonyms: ["text", "zoom", "bigger", "smaller"]),
            .init(id: "cursor-style", title: "Cursor Style", key: "cursor-style", section: .cursor, synonyms: ["block", "bar", "underline", "caret"]),
            .init(id: "cursor-style-blink", title: "Cursor Blink", key: "cursor-style-blink", section: .cursor, synonyms: ["blinking", "caret"]),
            .init(id: "unfocused-split-opacity", title: "Unfocused Pane Opacity", key: "unfocused-split-opacity", section: .splits, synonyms: ["dim", "split", "fade"]),
            .init(id: "resize-overlay", title: "Size Overlay", key: "resize-overlay", section: .splits, synonyms: ["resize", "columns", "rows"]),
            .init(id: "macos-option-as-alt", title: "Option Sends Meta", key: "macos-option-as-alt", section: .keyboard, synonyms: ["alt", "meta", "option", "esc"]),
            .init(id: "app-lock", title: "Require Face ID", section: .appLock, synonyms: ["face id", "touch id", "optic id", "passcode", "password", "lock", "privacy", "security"]),
            .init(id: "app-lock-grace", title: "Lock", section: .appLock, synonyms: ["lock", "background", "timeout", "minutes", "immediately"]),
            .init(id: "saved-passwords", title: "Saved Passwords", section: .passwords, synonyms: ["sudo", "ssh", "askpass", "keychain", "forget"]),
            .init(id: "ssh-keys", title: "SSH Keys", section: .sshKeys, synonyms: ["key", "ssh", "secure enclave", "ed25519", "rsa", "authorized_keys", "agent", "import", "generate"]),
            .init(id: "dictation", title: "Dictation", section: .voice, synonyms: ["voice", "speech", "microphone", "language"]),
            .init(id: "notify-approvals", title: "Approval Requests", section: .notifications, synonyms: ["notification", "approve", "deny", "push"]),
            .init(id: "notify-blocked", title: "Agent Needs You", section: .notifications, synonyms: ["notification", "question", "blocked", "waiting", "permission"]),
            .init(id: "notify-done", title: "Agent Finished", section: .notifications, synonyms: ["notification", "done", "complete", "idle"]),
            .init(id: "notify-agents", title: "Notifications by Agent", section: .notifications, synonyms: ["notification", "claude", "codex", "agent"]),
            .init(id: "notify-failed", title: "Agent Failed", section: .notifications, synonyms: ["notification", "error"]),
            .init(id: "notify-commands", title: "Long Commands", section: .notifications, synonyms: ["notification", "command", "finished"]),
            .init(id: "notify-background", title: "Only When the App Is in the Background", section: .notifications, synonyms: ["notification", "foreground"]),
            .init(id: "bell-features", title: "Flash Border on Bell", key: "bell-features", section: .bell, synonyms: ["bell", "beep", "alert"]),
            .init(id: "search-engine", title: "Search Engine", section: .browser, synonyms: ["browser", "google", "duckduckgo", "bing", "kagi", "brave", "search"]),
            .init(id: "website-language", title: "Language for Websites", section: .browser, synonyms: ["browser", "language", "english", "accept-language", "locale"]),
            .init(id: "search-region", title: "Search Region", section: .browser, synonyms: ["browser", "region", "country", "google", "bing"]),
            .init(id: "website-appearance", title: "Browser Appearance", section: .browser, synonyms: ["browser", "websites", "dark", "light", "theme", "color scheme", "dark mode"]),
            .init(id: "browser-history", title: "Clear Browsing History", section: .browser, synonyms: ["browser", "history", "recent", "frequent"]),
            .init(id: "accounts", title: "Agent Accounts", section: .accounts, synonyms: ["account", "sign in", "login", "personal", "work", "claude", "codex"]),
            .init(id: "agent-power", title: "Keep Mac awake while agents work", section: .agentTools, synonyms: ["sleep", "battery", "power", "awake", "plugged in"]),
            .init(id: "agent-tools", title: "Agent Hooks and Terminal Tools", section: .agentTools, synonyms: ["mcp", "claude", "codex", "browser", "drawings", "tools"]),
            .init(id: "record-agent-sessions", title: "Record Agent Sessions", section: .browser, synonyms: ["replay", "recording", "browser", "session", "rrweb"]),
            .init(id: "delete-replays", title: "Delete All Replays", section: .browser, synonyms: ["replay", "recording", "storage", "clear"]),
            .init(id: "merge-strategy", title: "Merge Pull Requests With", section: .git, synonyms: ["pr", "squash", "rebase", "merge"]),
            .init(id: "auto-delete", title: "Delete Merged Worktrees", section: .git, synonyms: ["worktree", "cleanup", "branch"]),
            .init(id: "git-scripts", title: "Scripts", section: .git, synonyms: ["run", "command", "⌘r"]),
            .init(id: "relay-mode", title: "Relays", section: .network, synonyms: ["relay", "iroh", "self-hosted", "local only", "network"]),
            .init(id: "relay-ca", title: "Import Certificate", section: .network, synonyms: ["certificate", "ca", "private", "relay", "tls"]),
            .init(id: "devices", title: "Paired Devices", section: .devices, synonyms: ["devices", "unpair", "remove", "sign out", "owner", "guests", "pairing", "security"]),
            .init(id: "devices-pair", title: "Pair a Device", section: .devices, synonyms: ["pair", "qr", "code", "phone", "ipad", "iphone", "add device", "rename"]),
            .init(id: "version", title: "Version", section: .about, synonyms: ["build", "about"]),
            .init(id: "acknowledgements", title: "Acknowledgements", section: .about, synonyms: ["licenses", "licences", "credits", "open source"]),
            .init(id: "privacy-policy", title: "Privacy Policy", section: .about, synonyms: ["privacy", "data"]),
            .init(id: "support", title: "Support", section: .about, synonyms: ["help", "contact", "feedback"]),
        ]
        #if os(iOS)
        entries += [
            .init(id: "tab-bar", title: "Tab Bar When the Sidebar Is Hidden", section: .appearance, synonyms: ["tabs", "strip"]),
            .init(id: "open-web-links", title: "Open Web Links In", section: .links, synonyms: ["link", "url", "safari", "browser"]),
            .init(id: "ascii-keyboard", title: "ASCII Keyboard", section: .keyboard, synonyms: ["keyboard", "autocorrect"]),
            .init(id: "hardware-key-bar", title: "With a Hardware Keyboard", section: .keyboard, synonyms: ["key bar", "esc", "pill", "magic keyboard"]),
            .init(id: "key-bar-profiles", title: "Key Bar Profiles", section: .keyboard, synonyms: ["key bar", "keys", "ctrl"]),
        ]
        #else
        entries.append(.init(id: "tab-bar", title: "Tab Bar When the Sidebar Is Hidden", section: .appearance, synonyms: ["tabs", "strip"]))
        entries += [
            .init(id: "this-mac-keep-running", title: "Keep Sessions Running in the Background", section: .thisMac, synonyms: ["helper", "daemon", "login item", "background", "quit"]),
            .init(id: "this-mac-helper", title: "Stop Helper", section: .thisMac, synonyms: ["helper", "daemon", "start", "local"]),
            .init(id: "this-mac-command-line-tool", title: "Command Line Tool", section: .thisMac, synonyms: ["cli", "terminal", "shell", "path", "pair", "devices"]),
        ]
        if AppUpdater.shared.isAvailable {
            entries += [
                .init(id: "updates-check-automatically", title: "Check for Updates Automatically", section: .about, synonyms: ["update", "upgrade", "sparkle", "new version"]),
                .init(id: "updates-download-automatically", title: "Download and Install Updates Automatically", section: .about, synonyms: ["update", "upgrade", "install"]),
            ]
        }
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
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            Spacer(minLength: DS.Space.s)
            Text(entry.breadcrumb)
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.textSecondary)
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
