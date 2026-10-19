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
            SwiftUI.Tab("Keyboard", systemImage: "keyboard") { pane { KeyboardSection() } }
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
            NavigationLink("Key Bar Profiles") { KeyBarProfilesView() }
            #endif
        } header: {
            Text("Keyboard")
        } footer: {
            Text("⌘ shortcuts always go to the app, never to the terminal.")
        }
    }
}

private struct NotificationsSection: View {
    @AppStorage("notify-needs-you") private var needsYou = true
    @AppStorage("notify-when-away") private var whenAway = true
    @AppStorage(TerminalPreferences.Key.bellFeatures) private var bellBorder = false

    var body: some View {
        Section {
            Toggle("When an Agent Needs You", isOn: $needsYou)
            Toggle("Only When Away from the Host", isOn: $whenAway)
                .disabled(!needsYou)
            Toggle(isOn: $bellBorder) { ConfigLabel("Flash Border on Bell", key: "bell-features = border") }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Away means the host has been idle or locked for three minutes.")
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
        var caps = profile.keys.map { key -> AnyView in
            if let title = key.title { return AnyView(KeyCap(title)) }
            return AnyView(Image(systemName: key.symbol ?? "questionmark").font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.background.secondary, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)))
        }
        if profile.showsCtrl { caps.insert(AnyView(KeyCap("ctrl")), at: min(profile.ctrlPosition, caps.count)) }
        return caps
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
