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

    var body: some View {
        #if os(macOS)
        // The window follows the terminal theme, like the workspace (Ghostty `window-theme`).
        ThemedRoot {
            NavigationSplitView {
                List(SettingsPane.allCases, selection: $pane) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .tag(pane)
                }
                .scrollContentBackground(.hidden)
                .background(DS.Palette.sidebar)
                .chromeContent()
                .navigationSplitViewColumnWidth(200)
            } detail: {
                Form { detail(pane).chromeRows() }
                    .formStyle(.grouped)
                    .chromeGrouped()
                    .navigationTitle(pane.title)
            }
            .frame(minWidth: 720, minHeight: 480)
        }
        #else
        NavigationStack(path: $path) {
            Form {
                AppearanceSection().chromeRows()
                FontSection().chromeRows()
                CursorSection().chromeRows()
                SplitsSection().chromeRows()
                KeyboardSection().chromeRows()
                PasswordsSection().chromeRows()
                VoiceSettingsSection().chromeRows()
                NotificationsSection().chromeRows()
                AgentsSettingsSection().chromeRows()
                GitSettingsSection().chromeRows()
                NetworkSettingsSection().chromeRows()
                AboutSection().chromeRows()
            }
            .chromeGrouped()
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

    #if os(macOS)
    @ViewBuilder private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .appearance: AppearanceSection()
        case .terminal: FontSection(); CursorSection(); SplitsSection(); PasswordsSection()
        case .keyboard: KeyboardSection(); VoiceSettingsSection()
        case .notifications: NotificationsSection()
        case .agents: AgentsSettingsSection()
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
private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case appearance, terminal, keyboard, notifications, agents, git, network, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .keyboard: "Keyboard"
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
                .foregroundStyle(.tertiary)
        }
    }
}

private struct AppearanceSection: View {
    @AppStorage(TerminalPreferences.Key.theme) private var theme = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    @AppStorage(TerminalPreferences.Key.paneStyle) private var paneStyle = TerminalPreferences.PaneStyle.compact
    @AppStorage(TabNaming.titleFromShell) private var titleFromShell = false
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true

    var body: some View {
        Section("Appearance") {
            NavigationLink {
                ThemePicker(selection: $theme)
            } label: {
                HStack {
                    ConfigLabel("Theme", key: "theme")
                    Spacer()
                    ThemeSwatch(theme: ThemeCatalog.theme(named: theme))
                    Text(theme).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityIdentifier("settings-theme")
            Picker(selection: $windowTheme) {
                ForEach(TerminalPreferences.WindowTheme.allCases) { Text($0.title).tag($0) }
            } label: {
                ConfigLabel("Window", key: "window-theme")
            }
            Picker(selection: $paneStyle) {
                ForEach(TerminalPreferences.PaneStyle.allCases) { Text($0.title).tag($0) }
            } label: {
                ConfigLabel("Panes", key: "pane-style")
            }
            Toggle(isOn: $titleFromShell) {
                ConfigLabel("Tab Title from Shell", key: "title-from-shell")
            }
            .accessibilityIdentifier("settings-title-from-shell")
            #if os(macOS)
            Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
            #else
            if UIDevice.current.userInterfaceIdiom != .phone {
                Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
            }
            #endif
        }
    }
}

private struct FontSection: View {
    @AppStorage(TerminalPreferences.Key.fontSize) private var fontSize = TerminalPreferences.Default.fontSize

    var body: some View {
        Section {
            LabeledContent {
                Text(TerminalPreferences.Default.fontFamily).foregroundStyle(.secondary)
            } label: {
                ConfigLabel("Family", key: "font-family")
            }
            Stepper(value: $fontSize, in: 8...32, step: 1) {
                HStack {
                    ConfigLabel("Size", key: "font-size")
                    Spacer()
                    Text("\(Int(fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("The quick brown fox jumps over the lazy dog 0O 1lI {}[]")
                .font(TerminalFont.font(size: fontSize))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.secondary)
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
            Toggle(isOn: $blink) { ConfigLabel("Blink", key: "cursor-style-blink") }
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
                    Text(opacity, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $opacity, in: 0.15...1)
            }
            Picker(selection: $resizeOverlay) {
                ForEach(TerminalPreferences.ResizeOverlay.allCases) { Text($0.title).tag($0) }
            } label: {
                ConfigLabel("Size Overlay", key: "resize-overlay")
            }
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
            #if os(iOS)
            Toggle("ASCII Keyboard", isOn: $asciiKeyboard)
            Picker("With a Hardware Keyboard", selection: $hardwareKeyBar) {
                Text("Esc Pill").tag(KeyBar.HardwareMode.minimal.rawValue)
                Text("Hidden").tag(KeyBar.HardwareMode.hidden.rawValue)
                Text("Full Key Bar").tag(KeyBar.HardwareMode.full.rawValue)
            }
            NavigationLink("Key Bar Profiles") { KeyBarProfilesView() }
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
        } header: {
            Text("Bell")
        }
    }
}

private struct AboutSection: View {
    var body: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            NavigationLink("Acknowledgements") { AcknowledgementsView() }
        }
    }
}

// MARK: - Theme picker

/// Ghostty's bundled themes, searchable, each with its palette and a sample line.
private struct ThemePicker: View {
    @Binding var selection: String
    @State private var query = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", dark = "Dark", light = "Light"
        var id: String { rawValue }
    }

    private var themes: [TerminalTheme] {
        let all = [TerminalTheme.ghosttyDefault] + ThemeCatalog.all
        return all.filter { theme in
            (query.isEmpty || theme.name.localizedCaseInsensitiveContains(query))
                && (filter == .all || (filter == .light) == theme.isLight)
        }
    }

    var body: some View {
        List {
            Picker("Appearance", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.l, bottom: DS.Space.s, trailing: DS.Space.l))
            .listRowSeparator(.hidden)

            ForEach(themes) { theme in
                Button {
                    selection = theme.name
                } label: {
                    ThemeCard(theme: theme, isSelected: theme.name == selection)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: DS.Space.xs, leading: DS.Space.l, bottom: DS.Space.xs, trailing: DS.Space.l))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("theme-\(theme.name)")
            }
        }
        .listStyle(.plain)
        .chromeGrouped()
        .searchable(text: $query, prompt: "\(ThemeCatalog.all.count + 1) themes")
        .navigationTitle("Theme")
    }
}

/// foreground, a prompt in its colours, and four swatches (red, green, blue, yellow). The selected
/// card has the window's accent ring.
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name)
                    .font(.body)
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                // A prompt line in the theme's own colours.
                HStack(spacing: 0) {
                    Text("~ ").foregroundStyle(theme.ansi(4))
                    Text("❯ ").foregroundStyle(theme.ansi(2))
                    Text("git ").foregroundStyle(theme.foreground)
                    Text("status").foregroundStyle(theme.ansi(3))
                }
                .font(TerminalFont.font(size: 12, relativeTo: .caption))
            }
            Spacer(minLength: DS.Space.s)
            ThemeSwatches(theme: theme)
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(DS.Palette.accent)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s + 2)
        .background(theme.background, in: .rect(cornerRadius: DS.Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(isSelected ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(theme.foreground.opacity(0.12)), lineWidth: isSelected ? 2 : 0.5)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                            .foregroundStyle(.secondary)
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
            Section {
                ack("Git logo", "Jason Long · CC BY 3.0 · creativecommons.org/licenses/by/3.0")
                ack("Neovim logo", "Jason Long · CC BY 3.0 · creativecommons.org/licenses/by/3.0")
                ack("Ruby logo", "© 2006 Yukihiro Matsumoto · CC BY-SA 2.5 · creativecommons.org/licenses/by-sa/2.5 · cropped to the gem")
                ack("tmux logo", "Copyright (c) 2015, Jason Long · ISC License: Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies. THE SOFTWARE IS PROVIDED \"AS IS\" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. Drawn in one colour.")
                ack("Helix logo", "@jakenvac · Mozilla Public License 2.0 · source: github.com/helix-editor/helix")
                ack("btop logo", "Aristocratos · Apache License 2.0 · github.com/aristocratos/btop")
            } header: {
                Text("Program logos")
            } footer: {
                Text("Shown next to a tab to say which program runs in it. The names and logos belong to their owners, who do not endorse this app.")
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
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .chromeRows()
    }

    private func link(_ title: String, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("ack-\(title)")
        .chromeRows()
    }
}
