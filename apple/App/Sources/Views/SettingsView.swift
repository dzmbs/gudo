import DesignSystem
import SwiftUI
import TerminalCore
import UnnamedCore

/// Ghostty's config surfaced as native settings. Each control shows the Ghostty key it mirrors, so
/// a Ghostty user can map their config file; the values are the same names and defaults.
/// macOS: the toolbar-tabbed Settings window. iOS: one grouped form in a sheet.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto

    private var scheme: ColorScheme? {
        switch windowTheme {
        case .system: nil
        case .auto: ThemeCatalog.theme(named: themeName).colorScheme
        case .light: .light
        case .dark: .dark
        }
    }

    var body: some View {
        #if os(macOS)
        TabView {
            SwiftUI.Tab("Appearance", systemImage: "paintpalette") { pane { AppearanceSection() } }
            SwiftUI.Tab("Terminal", systemImage: "terminal") { pane { FontSection(); CursorSection(); SplitsSection() } }
            SwiftUI.Tab("Keyboard", systemImage: "keyboard") { pane { KeyboardSection(); VoiceSettingsSection() } }
            SwiftUI.Tab("Notifications", systemImage: "bell.badge") { pane { NotificationsSection() } }
            SwiftUI.Tab("About", systemImage: "info.circle") { pane { AboutSection() } }
        }
        .frame(width: 560, height: 520)
        // The window follows the terminal theme, like the workspace (Ghostty `window-theme`).
        .preferredColorScheme(scheme)
        .environment(\.terminalTheme, ThemeCatalog.theme(named: themeName))
        #else
        NavigationStack {
            Form {
                AppearanceSection().raisedRows()
                FontSection().raisedRows()
                CursorSection().raisedRows()
                SplitsSection().raisedRows()
                KeyboardSection().raisedRows()
                VoiceSettingsSection().raisedRows()
                NotificationsSection().raisedRows()
                AboutSection().raisedRows()
            }
            .terminalGrouped()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #endif
    }

    private func pane(@ViewBuilder _ content: () -> some View) -> some View {
        NavigationStack {
            Form { content().raisedRows() }.formStyle(.grouped).terminalGrouped()
        }
    }
}

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
            .listRowInsets(EdgeInsets())

            ForEach(themes) { theme in
                Button {
                    selection = theme.name
                } label: {
                    ThemeRow(theme: theme, isSelected: theme.name == selection)
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $query, prompt: "\(ThemeCatalog.all.count + 1) themes")
        .navigationTitle("Theme")
    }
}

private struct ThemeRow: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.name).lineLimit(1)
                // A prompt line in the theme's own colors.
                HStack(spacing: 0) {
                    Text("~ ").foregroundStyle(theme.ansi(4))
                    Text("❯ ").foregroundStyle(theme.ansi(2))
                    Text("git ").foregroundStyle(theme.foreground)
                    Text("status").foregroundStyle(theme.ansi(3))
                }
                .font(TerminalFont.font(size: 12, relativeTo: .caption))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(theme.background, in: .rect(cornerRadius: DS.Radius.chip))
            }
            Spacer()
            ThemeSwatch(theme: theme)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(DS.Palette.accent)
                .opacity(isSelected ? 1 : 0)
        }
        .contentShape(.rect)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The eight normal ANSI colors as a strip on the theme background.
private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1..<7, id: \.self) { index in
                theme.ansi(index).frame(width: 6, height: 14)
            }
        }
        .padding(3)
        .background(theme.background)
        .clipShape(.rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
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
            }
        }
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
                .background(.background.secondary, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)))
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
        .navigationTitle("Acknowledgements")
    }

    private func ack(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
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
    }
}
