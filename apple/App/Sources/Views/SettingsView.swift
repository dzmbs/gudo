import DesignSystem
import SwiftUI
import TerminalCore
import UnnamedCore

/// Ghostty's config surfaced as native settings. Each control shows the Ghostty key it mirrors, so
/// a Ghostty user can map their config file; the values are the same names and defaults.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @State private var pane = SettingsPane.appearance
    #else
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    /// `-screen themes` opens the theme picker (design review).
    @State private var path: [SettingsPage] = LaunchOptions.screen == "themes" ? [.theme] : []
    #endif

    /// Settings search: the query, and the row a result jumped to (lit for a moment).
    @State private var query = ""
    @State private var highlight: String?
    @State private var jump: SettingsEntry?

    var body: some View {
        #if os(macOS)
        // The window follows the terminal theme, like the workspace (Ghostty `window-theme`).
        ThemedRoot {
            NavigationSplitView {
                Group {
                    if query.isEmpty {
                        List(SettingsPane.allCases, selection: $pane) { pane in
                            Label(pane.title, systemImage: pane.systemImage)
                                .tag(pane)
                        }
                    } else {
                        // Results replace the panes while searching; the search stays.
                        let results = SettingsIndex.search(query)
                        List {
                            ForEach(results) { entry in
                                Button { jump = entry } label: { SettingsResultRow(entry: entry) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .overlay { if results.isEmpty { SettingsNoResults(query: query) } }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(DS.Palette.sidebar)
                .chromeContent()
                .searchable(text: $query, placement: .sidebar, prompt: "Search")
                .navigationSplitViewColumnWidth(220)
            } detail: {
                ScrollViewReader { proxy in
                    Form { detail(pane).chromeRows() }
                        .formStyle(.grouped)
                        .chromeGrouped()
                        .navigationTitle(pane.title)
                        .environment(\.settingsHighlight, highlight)
                        .onChange(of: jump) { _, entry in
                            guard let entry else { return }
                            pane = entry.section.pane
                            reveal(entry, proxy: proxy)
                        }
                }
            }
            .frame(minWidth: 720, minHeight: 480)
        }
        #else
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                Group {
                    if query.isEmpty {
                        form
                    } else {
                        SettingsResults(query: query) { entry in
                            query = ""
                            reveal(entry, proxy: proxy)
                        }
                    }
                }
                .chromeGrouped()
                .environment(\.settingsHighlight, highlight)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Settings or Ghostty Keys")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsPage.self) { _ in ThemePicker(selection: $themeName) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    private var form: some View {
        Form {
            AppearanceSection().chromeRows()
            FontSection().chromeRows()
            CursorSection().chromeRows()
            SplitsSection().chromeRows()
            LinksSettingsSection().chromeRows()
            BrowserSettingsSection().chromeRows()
            KeyboardSection().chromeRows()
            PasswordsSection().chromeRows()
            VoiceSettingsSection().chromeRows()
            NotificationsSection().chromeRows()
            AgentsSettingsSection().chromeRows()
            AgentToolsSection().chromeRows()
            GitSettingsSection().chromeRows()
            NetworkSettingsSection().chromeRows()
            AboutSection().chromeRows()
        }
    }
    #endif

    /// Scrolls to a result's row once it is laid out, and lights it for a moment.
    private func reveal(_ entry: SettingsEntry, proxy: ScrollViewProxy) {
        Task { @MainActor in
            // The form (iOS) or the pane (Mac) replaces the results first.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(DS.Motion.snappy) { proxy.scrollTo(entry.id, anchor: .center) }
            highlight = entry.id
            // Once more after the search bar has closed and the form settled.
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(DS.Motion.snappy) { proxy.scrollTo(entry.id, anchor: .center) }
            try? await Task.sleep(for: .seconds(1.6))
            if highlight == entry.id { highlight = nil }
            if jump == entry { jump = nil }
        }
    }

    #if os(macOS)
    @ViewBuilder private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .appearance: AppearanceSection()
        case .terminal: FontSection(); CursorSection(); SplitsSection(); LinksSettingsSection(); PasswordsSection()
        case .keyboard: KeyboardSection(); VoiceSettingsSection()
        case .browser: BrowserSettingsSection()
        case .notifications: NotificationsSection()
        case .agents: AgentsSettingsSection(); AgentToolsSection()
        case .git: GitSettingsSection()
        case .network: NetworkSettingsSection()
        case .about: AboutSection()
        }
    }
    #endif
}

#if os(iOS)
/// Pages pushed onto the iOS Settings stack by value.
private enum SettingsPage: Hashable {
    case theme
}
#endif

#if os(macOS)
/// The Mac Settings window's panes, in its sidebar.
nonisolated enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance, terminal, keyboard, browser, notifications, agents, git, network, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .keyboard: "Keyboard"
        case .browser: "Browser"
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .git: "Git"
        case .network: "Network"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .terminal: "terminal"
        case .keyboard: "keyboard"
        case .browser: "globe"
        case .notifications: "bell.badge"
        case .agents: "sparkle"
        case .git: "arrow.triangle.branch"
        case .network: "network"
        case .about: "info.circle"
        }
    }
}
#endif

/// A setting's label: its title and, underneath, the Ghostty config key in SF Mono.
private struct ConfigLabel: View {
    let title: String
    let key: String

    init(_ title: String, key: String) {
        self.title = title
        self.key = key
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(key)
                .font(DS.Font.literalSmall)
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

private struct AppearanceSection: View {
    @AppStorage(TerminalPreferences.Key.theme) private var theme = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact
    @AppStorage(TabNaming.titleFromShell) private var titleFromShell = false
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true
    @AppStorage(ThemePair.enabledKey) private var themePair = false

    var body: some View {
        Section("Appearance") {
            if !themePair {
                NavigationLink {
                    ThemePicker(selection: $theme)
                } label: {
                    HStack {
                        ConfigLabel("Theme", key: "theme")
                        Spacer()
                        ThemeSwatch(theme: ThemeCatalog.theme(named: theme))
                        Text(theme).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                    }
                }
                .accessibilityIdentifier("settings-theme")
                .settingAnchor("theme")
            }
            ThemePairRows { ThemePicker(selection: $0) }
            Picker(selection: $paneStyle) {
                ForEach(TerminalPreferences.PaneStyle.allCases) { Text($0.title).tag($0) }
            } label: {
                ConfigLabel("Panes", key: "pane-style")
            }
            .settingAnchor("pane-style")
            Toggle(isOn: $titleFromShell) {
                ConfigLabel("Tab Title from Shell", key: "title-from-shell")
            }
            .accessibilityIdentifier("settings-title-from-shell")
            .settingAnchor("title-from-shell")
            #if os(macOS)
            Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
                .settingAnchor("tab-bar")
            #else
            if UIDevice.current.userInterfaceIdiom != .phone {
                Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
                    .settingAnchor("tab-bar")
            }
            #endif
            windowRows
        }
    }

    /// The window takes the theme's colours unless the user keeps it light, dark or with the
    /// system. Turning matching off starts on the scheme opposite the theme's, so the change shows.
    @ViewBuilder private var windowRows: some View {
        let matches = Binding {
            windowTheme == .auto
        } set: { on in
            windowTheme = on ? .auto : (ThemeCatalog.theme(named: theme).isLight ? .dark : .light)
        }
        Toggle(isOn: matches.animation(DS.Motion.quick)) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Window Matches Theme")
                Text("Sidebar, toolbar and key bar in the theme's colours")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .accessibilityIdentifier("settings-window-matches-theme")
        .settingAnchor("window-theme")
        if windowTheme != .auto {
            Picker(selection: $windowTheme) {
                ForEach(TerminalPreferences.WindowTheme.separate) { Text($0.title).tag($0) }
            } label: {
                ConfigLabel("Window Appearance", key: "window-theme")
            }
            .accessibilityIdentifier("settings-window-appearance")
        }
    }
}

private struct FontSection: View {
    @AppStorage(TerminalPreferences.Key.fontSize) private var fontSize = TerminalPreferences.Default.fontSize

    var body: some View {
        Section {
            LabeledContent {
                Text(TerminalPreferences.Default.fontFamily).foregroundStyle(DS.Palette.textSecondary)
            } label: {
                ConfigLabel("Family", key: "font-family")
            }
            .settingAnchor("font-family")
            Stepper(value: $fontSize, in: 8...32, step: 1) {
                HStack {
                    ConfigLabel("Size", key: "font-size")
                    Spacer()
                    Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .settingAnchor("font-size")
            Text("The quick brown fox jumps over the lazy dog 0O 1lI {}[]")
                .font(TerminalFont.font(size: fontSize))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(DS.Palette.textSecondary)
        } header: {
            Text("Font")
        }
    }
}

private struct CursorSection: View {
    @AppStorage(TerminalPreferences.Key.cursorStyle) private var style = TerminalPreferences.CursorStyle.block
    @AppStorage(TerminalPreferences.Key.cursorBlink) private var blink = true

    var body: some View {
        Section("Cursor") {
            Picker(selection: $style) {
                ForEach(TerminalPreferences.CursorStyle.allCases) { Text($0.title).tag($0) }
            } label: {
                ConfigLabel("Style", key: "cursor-style")
            }
            .settingAnchor("cursor-style")
            Toggle(isOn: $blink) { ConfigLabel("Blink", key: "cursor-style-blink") }
                .settingAnchor("cursor-style-blink")
        }
    }
}

private struct SplitsSection: View {
    @AppStorage(TerminalPreferences.Key.unfocusedSplitOpacity) private var opacity = TerminalPreferences.Default.unfocusedSplitOpacity
    @AppStorage(TerminalPreferences.Key.resizeOverlay) private var resizeOverlay = TerminalPreferences.ResizeOverlay.afterFirst

    var body: some View {
        Section("Splits") {
            VStack(alignment: .leading) {
                HStack {
                    ConfigLabel("Unfocused Pane Opacity", key: "unfocused-split-opacity")
                    Spacer()
                    Text(opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                }
                Slider(value: $opacity, in: 0.15...1)
            }
            .settingAnchor("unfocused-split-opacity")
            Picker(selection: $resizeOverlay) {
                ForEach(TerminalPreferences.ResizeOverlay.allCases) { Text($0.title).tag($0) }
            } label: {
                ConfigLabel("Size Overlay", key: "resize-overlay")
            }
            .settingAnchor("resize-overlay")
        }
    }
}

private struct KeyboardSection: View {
    // The terminal reads these two keys (Workspace.applyKeyboardSettings).
    @AppStorage(KeyboardSettings.optionAsMeta) private var optionAsMeta = OptionAsMeta.none.rawValue
    @AppStorage(KeyboardSettings.asciiKeyboard) private var asciiKeyboard = false
    #if os(iOS)
    @AppStorage(KeyBar.hardwareModeKey) private var hardwareKeyBar = KeyBar.HardwareMode.minimal.rawValue
    #endif

    var body: some View {
        Section {
            Picker(selection: $optionAsMeta) {
                Text("Off").tag(OptionAsMeta.none.rawValue)
                Text("Left Option").tag(OptionAsMeta.left.rawValue)
                Text("Right Option").tag(OptionAsMeta.right.rawValue)
                Text("Both").tag(OptionAsMeta.both.rawValue)
            } label: {
                ConfigLabel("Option Sends Meta", key: "macos-option-as-alt")
            }
            .settingAnchor("macos-option-as-alt")
            #if os(iOS)
            Toggle("ASCII Keyboard", isOn: $asciiKeyboard)
                .settingAnchor("ascii-keyboard")
            Picker("With a Hardware Keyboard", selection: $hardwareKeyBar) {
                Text("Esc Pill").tag(KeyBar.HardwareMode.minimal.rawValue)
                Text("Hidden").tag(KeyBar.HardwareMode.hidden.rawValue)
                Text("Full Key Bar").tag(KeyBar.HardwareMode.full.rawValue)
            }
            .settingAnchor("hardware-key-bar")
            NavigationLink("Key Bar Profiles") { KeyBarProfilesView() }
                .settingAnchor("key-bar-profiles")
            #endif
        } header: {
            Text("Keyboard")
        } footer: {
            #if os(iOS)
            Text("⌘ shortcuts always go to the app, never to the terminal. The Magic Keyboard has no Esc key: ⌘. sends Esc, or set Caps Lock to Escape in Settings ▸ General ▸ Keyboard ▸ Hardware Keyboard.")
            #else
            Text("⌘ shortcuts always go to the app, never to the terminal.")
            #endif
        }
    }
}

/// Per-kind notification choices (`NotificationPrefsSection`, Notifications/) plus the bell.
private struct NotificationsSection: View {
    @AppStorage(TerminalPreferences.Key.bellFeatures) private var bellBorder = false

    var body: some View {
        NotificationPrefsSection()
        Section {
            Toggle(isOn: $bellBorder) { ConfigLabel("Flash Border on Bell", key: "bell-features = border") }
                .settingAnchor("bell-features")
        } header: {
            Text("Bell")
        }
    }
}

private struct AboutSection: View {
    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                .settingAnchor("version")
            NavigationLink("Acknowledgements") { AcknowledgementsView() }
                .settingAnchor("acknowledgements")
        }
    }
}

private struct ThemeSwatches: View {
    let theme: TerminalTheme
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            ForEach([1, 2, 4, 3], id: \.self) { index in
                Circle()
                    .fill(theme.ansi(index))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The current theme beside its setting: its background and foreground as a tile, then its four
/// swatches.
private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 6) {
            Text("Aa")
                .font(TerminalFont.font(size: 11, relativeTo: .caption2))
                .foregroundStyle(theme.foreground)
                .frame(width: 26, height: 18)
                .background(theme.background, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
            ThemeSwatches(theme: theme, size: 8)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Key bar profiles

/// Editing lands with custom profiles.
private struct KeyBarProfilesView: View {
    var body: some View {
        List {
            ForEach(KeyBarProfile.builtIn) { profile in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    HStack {
                        Text(profile.name).font(DS.Font.rowTitleEmphasis)
                        Spacer()
                        Text(profile.programs.sorted().prefix(3).joined(separator: ", "))
                            .font(DS.Font.literalSmall)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: DS.Space.xs) {
                            ForEach(Array(caps(profile).enumerated()), id: \.offset) { _, cap in cap }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.vertical, DS.Space.xs)
                .chromeRows()
            }
        }
        .chromeGrouped()
        .navigationTitle("Key Bar Profiles")
    }

    private func caps(_ profile: KeyBarProfile) -> [AnyView] {
        // Capsule A is the same in every profile; capsule B follows it, in priority order.
        let spine = ["esc", "ctrl", "alt", "⇥"].map { AnyView(KeyCap($0)) }
        let wing = profile.keys.map { key -> AnyView in
            if let title = key.title {
                return AnyView(KeyCap(title))
            }
            return AnyView(Image(systemName: key.symbol ?? "questionmark").font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Palette.separator, lineWidth: 0.5)))
        }
        return spine + wing
    }
}

private struct AcknowledgementsView: View {
    var body: some View {
        List {
            ack("Ghostty", "MIT · terminal core (libghostty-vt), split, overlay and palette designs")
            ack("JetBrains Mono", "SIL Open Font License 1.1 · terminal font")
            ack("Nerd Fonts", "MIT and per-icon-set licenses · symbols in the terminal font")
            ack("iTerm2-Color-Schemes", "MIT · terminal themes, as bundled by Ghostty")
            ack("Orca", "MIT · key bar and reconnect behaviour")
            ack("Warp UI framework", "MIT · Copyright (C) 2020-2026 Denver Technologies, Inc. · the “working” shimmer")
            Section {
                ack("Git logo", "Jason Long · CC BY 3.0 · creativecommons.org/licenses/by/3.0")
                ack("Neovim logo", "Jason Long · CC BY 3.0 · creativecommons.org/licenses/by/3.0")
                ack("Ruby logo", "© 2006 Yukihiro Matsumoto · CC BY-SA 2.5 · creativecommons.org/licenses/by-sa/2.5 · cropped to the gem")
                ack("tmux logo", "Copyright (c) 2015, Jason Long · ISC License: Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies. THE SOFTWARE IS PROVIDED \"AS IS\" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. Drawn in one colour.")
                ack("Helix logo", "@jakenvac · Mozilla Public License 2.0 · source: github.com/helix-editor/helix")
                ack("btop logo", "Aristocratos · Apache License 2.0 · github.com/aristocratos/btop")
                ack("Emacs logo", "Copyright (C) 2015-2026 Free Software Foundation, Inc. · Nicolas Petton · GNU General Public License v3 or later · unmodified; source: git.savannah.gnu.org/cgit/emacs.git")
                ack("htop logo", "htop authors · GNU General Public License v2 or later · unmodified; source: github.com/htop-dev/htop")
                ack("Rust and Cargo logos", "Rust Foundation · Creative Commons Attribution 4.0 · creativecommons.org/licenses/by/4.0 · unmodified · Rust and Cargo are trademarks of the Rust Foundation")
                ack("Claude logo", "Anthropic, PBC · Claude is a trademark of Anthropic, PBC")
                ack("OpenAI logo", "OpenAI · labels Codex · OpenAI, Codex and the OpenAI logo are trademarks of OpenAI")
                ack("Gemini CLI icon", "Google LLC · Gemini is a trademark of Google LLC")
                ack("GitHub Copilot icon", "GitHub, Inc. · GitHub and Copilot are trademarks of GitHub, Inc.")
                ack("Vim logo", "The Vim project · vim.org")
                ack("Docker logo", "Docker, Inc. · Docker and the Docker logo are trademarks or registered trademarks of Docker, Inc. in the United States and/or other countries")
                ack("Kubernetes logo", "The Linux Foundation · labels kubectl · Kubernetes is a registered trademark of The Linux Foundation")
                ack("Python logo", "Python Software Foundation · “Python” and the Python logos are trademarks or registered trademarks of the Python Software Foundation")
                ack("Node.js logo", "OpenJS Foundation · Node.js is a trademark of the OpenJS Foundation")
                ack("Bun logo", "Oven · bun.com")
                ack("Deno logo", "Deno Land Inc. · Deno is a registered trademark of Deno Land Inc.")
                ack("Go logo", "Google LLC · Go and the Go Logo are trademarks of Google LLC")
                ack("PostgreSQL logo", "PostgreSQL Community Association · Postgres, PostgreSQL and the Slonik logo are trademarks or registered trademarks of the PostgreSQL Community Association of Canada")
            } header: {
                Text("Program logos")
            } footer: {
                Text("Claude is a trademark of Anthropic, PBC; the other names and logos above are trademarks of their owners. Names and logos are used only to identify the program running in a tab; this app is not affiliated with or endorsed by them.")
            }
            Section {
                ack("Visual Studio Code", "Microsoft Software License Terms · the editor. Its server and CLI are downloaded from Microsoft onto your own hosts when you open the editor; they are not part of this app.")
                link("Visual Studio Code License", vscodeLicenseUrl())
                link("Visual Studio Code Server License", vscodeServerLicenseUrl())
                link("Microsoft Privacy Statement", microsoftPrivacyUrl())
            } header: {
                Text("Licenses")
            } footer: {
                Text("Opening the editor uses VS Code under these terms, for you, on hosts you control.")
            }
        }
        .chromeGrouped()
        .navigationTitle("Acknowledgements")
    }

    private func ack(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail).font(.footnote).foregroundStyle(DS.Palette.textSecondary)
        }
        .chromeRows()
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .accessibilityIdentifier("ack-\(title)")
        .chromeRows()
    }
}
