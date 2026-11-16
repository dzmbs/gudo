import DesignSystem
import SwiftUI
import TerminalCore
import GudoCore

/// Ghostty's config surfaced as native settings. Each control shows the Ghostty key it mirrors, so
/// a Ghostty user can map their config file; the values are the same names and defaults.
/// macOS: a list of panes beside a grouped form, shaped like System Settings. iOS: one grouped
/// form in a sheet.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @State private var navigation: SettingsNavigation
    /// The panes list holds the keyboard as the window opens; the search only once clicked.
    @FocusState private var focus: SettingsFocus?
    #else
    /// `-screen themes` opens the theme picker, `-screen devices` a host's devices (design review).
    @State private var path: [SettingsPage] = Self.fixturePath

    private static var fixturePath: [SettingsPage] {
        switch LaunchOptions.screen {
        case "themes": [.theme]
        case "devices": [.hostDevices("studio")]
        default: []
        }
    }
    #endif

    /// Settings search: the query, and the row a result jumped to (lit for a moment).
    @State private var query = ""
    @State private var highlight: String?
    @State private var jump: SettingsEntry?
    #if os(macOS)
    private static let sidebarWidth: CGFloat = 220

    /// Whether `event` is the user's own click or key, rather than AppKit settling a new window.
    static func isUserEvent(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .leftMouseDown, .leftMouseUp, .keyDown: true
        default: false
        }
    }

    init(navigation: SettingsNavigation = SettingsNavigation()) {
        _navigation = State(initialValue: navigation)
    }
    #endif

    var body: some View {
        #if os(macOS)
        // The window follows the terminal theme, like the workspace (Ghostty `window-theme`).
        ThemedRoot {
            // System Settings' shape: a full-height sidebar under the traffic lights (search,
            // then the panes), no toggle; the pane's title in the titlebar over the form.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    SettingsSearchField(query: $query, focus: $focus)
                        .padding(.horizontal, DS.Space.m)
                        .padding(.top, DS.Space.xs)
                        .padding(.bottom, DS.Space.s)
                    if query.isEmpty {
                        SettingsSidebar(selection: $navigation.pane)
                            .focused($focus, equals: .panes)
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
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .frame(width: Self.sidebarWidth)
                .background { Rectangle().fill(DS.Palette.sidebar).ignoresSafeArea() }
                .chromeContent()
                Hairline(.vertical, style: DS.Palette.separator)
                    .ignoresSafeArea()
                // A stack, so the theme picker pushes with a way back.
                NavigationStack(path: $navigation.path) {
                    ScrollViewReader { proxy in
                        Form { detail(navigation.pane).chromeRows() }
                            .formStyle(.grouped)
                            // Each pane opens at its top, never where the last one was left.
                            .defaultScrollAnchor(.top, for: .initialOffset)
                            .id(navigation.pane)
                            .chromeGrouped()
                            .titleBarEdge()
                            .navigationTitle(navigation.pane.title)
                            .environment(\.settingsHighlight, highlight)
                            .navigationDestination(for: SettingsPage.self) { SettingsPageView(page: $0) }
                        .onChange(of: jump) { _, entry in
                            guard let entry else { return }
                            navigation.pane = entry.section.pane
                            reveal(entry, proxy: proxy)
                        }
                    }
                }
            }
            .defaultFocus($focus, .panes)
            // AppKit hands a new window's keyboard to its first text field: the search takes it
            // only from a click or a key.
            .onChange(of: focus) { _, focused in
                if focused == .search, !Self.isUserEvent(NSApp.currentEvent) { focus = .panes }
            }
            .onAppear(perform: followLink)
            .onChange(of: SettingsLink.shared.pending) { followLink() }
            .toolbar {
                // The title starts over the form, not over the sidebar: the traffic lights take
                // the sidebar's first 78 pt.
                ToolbarItem(placement: .navigation) {
                    Color.clear.frame(width: Self.sidebarWidth - 78, height: 1).accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
                // System Settings' back chevron, at the detail's leading edge before the title
                // (the stack's own would sit over the sidebar).
                if !navigation.path.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button("Back", systemImage: "chevron.left") { navigation.path.removeLast() }
                            .help("Back")
                            .keyboardShortcut("[", modifiers: .command)
                            .accessibilityIdentifier("settings-back")
                    }
                }
            }
            // A pinned ideal size: the window opens at one size whichever pane's form is longer.
            .frame(minWidth: 720, idealWidth: 760, minHeight: 480, idealHeight: 720)
            .chromeWindow()
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Settings")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsPage.self) { SettingsPageView(page: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: followLink)
        .onChange(of: SettingsLink.shared.pending) { followLink() }
        #endif
    }

    /// Shows the page a notification or toast asked for.
    private func followLink() {
        guard let page = SettingsLink.shared.pending else { return }
        SettingsLink.shared.pending = nil
        query = ""
        #if os(macOS)
        navigation.pane = page.pane
        navigation.path = [page]
        #else
        path = [page]
        #endif
    }

    #if os(iOS)
    private var form: some View {
        Form {
            AppearanceSection().chromeRows()
            PanesSettingsSection().chromeRows()
            TabsSettingsSection().chromeRows()
            FontSection().chromeRows()
            CursorSection().chromeRows()
            SplitsSection().chromeRows()
            LinksSettingsSection().chromeRows()
            FileLinksSettingsSection().chromeRows()
            BrowserSettingsSection().chromeRows()
            ReplaySettingsSection().chromeRows()
            KeyboardSection().chromeRows()
            AppLockSection().chromeRows()
            PasswordsSection().chromeRows()
            SSHKeysSettingsSection().chromeRows()
            VoiceSettingsSection().chromeRows()
            NotificationsSection().chromeRows()
            AccountsSettingsSection().chromeRows()
            AgentToolsSection().chromeRows()
            AgentPowerSettings().chromeRows()
            GitSettingsSection().chromeRows()
            NetworkSettingsSection().chromeRows()
            DevicesSettingsSection().chromeRows()
            AboutSection().chromeRows()
        }
    }
    #endif

    /// Scrolls to a result's row once it is laid out, and lights it for a moment.
    private func reveal(_ entry: SettingsEntry, proxy: ScrollViewProxy) {
        Task { @MainActor in
            // The form (iOS) or the pane (Mac) replaces the results first.
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(DS.Motion.standard) { proxy.scrollTo(entry.id, anchor: .center) }
            highlight = entry.id
            // Once more after the search bar has closed and the form settled.
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(DS.Motion.standard) { proxy.scrollTo(entry.id, anchor: .center) }
            try? await Task.sleep(for: .seconds(1.6))
            if highlight == entry.id { highlight = nil }
            if jump == entry { jump = nil }
        }
    }

    #if os(macOS)
    @ViewBuilder private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .appearance: AppearanceSection(); PanesSettingsSection(); TabsSettingsSection()
        case .terminal: FontSection(); CursorSection(); SplitsSection(); LinksSettingsSection(); FileLinksSettingsSection()
        case .keyboard: KeyboardSection(); VoiceSettingsSection()
        case .browser: BrowserSettingsSection(); ReplaySettingsSection()
        case .notifications: NotificationsSection()
        case .privacy: AppLockSection(); PasswordsSection(); SSHKeysSettingsSection()
        case .agents: AccountsSettingsSection(); AgentToolsSection(); AgentPowerSettings()
        case .git: GitSettingsSection()
        case .network: NetworkSettingsSection()
        case .devices: DevicesSettingsSection()
        case .thisMac: ThisMacSettingsSection()
        case .about: AboutSection()
        }
    }
    #endif
}

/// Pages pushed onto the Settings stack by value.
enum SettingsPage: Hashable {
    case theme, lightTheme, darkTheme, keyBarProfiles, acknowledgements, sshKeys
    /// A host's paired devices and guests.
    case hostDevices(String)
    /// A host's agent accounts.
    case hostAccounts(String)

    #if os(macOS)
    /// The pane it is pushed over.
    var pane: SettingsPane {
        switch self {
        case .theme, .lightTheme, .darkTheme: .appearance
        case .keyBarProfiles: .keyboard
        case .acknowledgements: .about
        case .sshKeys: .privacy
        case .hostDevices: .devices
        case .hostAccounts: .agents
        }
    }
    #endif
}

/// Asks Settings to show a page: from a notification, a toast or another window.
@MainActor
@Observable
final class SettingsLink {
    static let shared = SettingsLink()
    /// The page to show; Settings takes it when it appears or is already open.
    var pending: SettingsPage?
    /// Bumped to have a window bring the Mac Settings window forward.
    private(set) var openRequests = 0

    func open(_ page: SettingsPage) {
        pending = page
        #if os(macOS)
        bringForward()
        #else
        ActiveWindow.model?.sheet = .settings
        #endif
    }

    #if os(macOS)
    func bringForward() {
        openRequests += 1
    }
    #endif
}

#if os(macOS)
enum SettingsWindow {
    static let id = "settings"
}

/// Opens the Settings window when `SettingsLink` asks (only a view can open a window).
struct SettingsLinkOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: SettingsLink.shared.openRequests) { openWindow(id: SettingsWindow.id) }
    }
}

/// The app menu's Settings… (⌘,), which a `Window` scene does not add itself.
struct SettingsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") { openWindow(id: SettingsWindow.id) }
            .keyboardShortcut(",", modifiers: .command)
    }
}
#endif

/// A pushed page.
private struct SettingsPageView: View {
    let page: SettingsPage
    @AppStorage(TerminalPreferences.Key.theme) private var theme = TerminalPreferences.Default.theme
    @AppStorage(ThemePair.lightKey) private var light = ThemePair.resolvedDefaultLight
    @AppStorage(ThemePair.darkKey) private var dark = ThemePair.defaultDark

    var body: some View {
        Group {
            switch page {
            case .theme: ThemePicker(selection: $theme)
            case .lightTheme: ThemePicker(selection: $light)
            case .darkTheme: ThemePicker(selection: $dark)
            case .keyBarProfiles:
                #if os(iOS)
                KeyBarProfilesView()
                #endif
            case .acknowledgements: AcknowledgementsView()
            case .sshKeys: SSHKeysView(hosts: AppModel.shared.hosts)
            case .hostDevices(let id): HostDevicesView(hostId: id)
            case .hostAccounts(let id): HostAccountsView(hostId: id)
            }
        }
        #if os(macOS)
        // The window's toolbar has the back button (`SettingsView`).
        .navigationBarBackButtonHidden()
        #endif
    }
}

#if os(macOS)
/// The Mac window's pane and the pages pushed over it. Choosing a pane starts it at its root,
/// as System Settings does.
@Observable
final class SettingsNavigation {
    var pane: SettingsPane {
        didSet { if pane != oldValue { path = [] } }
    }
    var path: [SettingsPage]

    init(pane: SettingsPane = .appearance, path: [SettingsPage] = []) {
        self.pane = pane
        self.path = path
    }
}
#endif

#if os(macOS)
/// The Mac Settings window's panes, in its sidebar.
nonisolated enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance, terminal, keyboard, browser, notifications, privacy, agents, git, network, devices, thisMac, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .keyboard: "Keyboard"
        case .browser: "Browser"
        case .notifications: "Notifications"
        case .privacy: "Privacy & Security"
        case .agents: "Agents"
        case .git: "Git"
        case .network: "Network"
        case .devices: "Devices"
        case .thisMac: "This Mac"
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
        case .privacy: "hand.raised"
        case .agents: "sparkle"
        case .git: "arrow.triangle.branch"
        case .network: "network"
        case .devices: "laptopcomputer.and.iphone"
        case .thisMac: "laptopcomputer"
        case .about: "info.circle"
        }
    }
}
#endif

/// A setting's label: its title and, underneath, the Ghostty config key in SF Mono.
private struct ConfigLabel: View {
    let title: String
    let key: String
    #if os(macOS)
    @State private var showsKey = false
    #endif

    init(_ title: String, key: String) {
        self.title = title
        self.key = key
    }

    var body: some View {
        // The key is reference, not a label: in search results and the tooltip, and under the
        // title while ⌥ is held on the Mac.
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            #if os(macOS)
            if showsKey {
                Text(key)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            #endif
        }
        .help("Ghostty: \(key)")
        #if os(macOS)
        .onModifierKeysChanged(mask: .option, initial: true) { _, keys in showsKey = keys.contains(.option) }
        #endif
    }
}

/// What a window opens with.
private struct TabsSettingsSection: View {
    @AppStorage(LaunchTabs.key) private var launch = LaunchTabs.previous

    var body: some View {
        Section {
            Picker("\(Brand.name) Opens With", selection: $launch) {
                ForEach(LaunchTabs.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings-launch-tabs")
            .settingAnchor("launch-tabs")
        } header: {
            PaneSectionTitle("Tabs")
        } footer: {
            Text(launch == .previous
                ? "Every tab comes back as you left it."
                : "Your other tabs keep running on their hosts: Restore in the sidebar or History ▸ Reopen Previous Tabs brings them back. Tabs with an agent or a command running always come back.")
        }
    }
}

private struct AppearanceSection: View {
    @AppStorage(TerminalPreferences.Key.theme) private var theme = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    @AppStorage(TerminalPreferences.Key.sidebarTextSize) private var sidebarTextSize = TerminalPreferences.Default.sidebarTextSize
    @AppStorage(ToastPosition.key) private var toastPosition = ToastPosition.standard
    @AppStorage(TabNaming.titleFromShell) private var titleFromShell = false
    @AppStorage(TabPlacement.showsTabBarKey) private var showsTabBar = true
    @AppStorage(ThemePair.enabledKey) private var themePair = false
    @AppStorage(ProgramTileTint.key) private var programMarkTint = ProgramTileTint.original

    var body: some View {
        Section {
            if !themePair {
                NavigationLink(value: SettingsPage.theme) {
                    HStack {
                        // The word stays whole at the largest text sizes; the theme's name gives way.
                        ConfigLabel("Theme", key: "theme")
                            .layoutPriority(1)
                        Spacer()
                        ThemeSwatch(theme: ThemeCatalog.theme(named: theme))
                        Text(theme).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                    }
                }
                .accessibilityIdentifier("settings-theme")
                .settingAnchor("theme")
            }
            ThemePairRows()
            if !Self.isPhone {
                Picker("Sidebar Text Size", selection: $sidebarTextSize) {
                    ForEach(TerminalPreferences.SidebarTextSize.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings-sidebar-text-size")
                .settingAnchor("sidebar-text-size")
            }
            Picker("Toasts", selection: $toastPosition) {
                ForEach(ToastPosition.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings-toast-position")
            .settingAnchor("toast-position")
            Picker("Program Marks", selection: $programMarkTint) {
                ForEach(ProgramTileTint.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("settings-program-marks")
            .settingAnchor("program-marks")
            Toggle(isOn: $titleFromShell) {
                ConfigLabel("Tab Title from Shell", key: "title-from-shell")
            }
            .accessibilityIdentifier("settings-title-from-shell")
            .settingAnchor("title-from-shell")
            if !Self.isPhone {
                Toggle("Tab Bar When the Sidebar Is Hidden", isOn: $showsTabBar)
                    .settingAnchor("tab-bar")
            }
            windowRows
        } header: {
            PaneSectionTitle("Appearance")
        }
    }

    /// The sidebar and the tab strip are the Mac's and the iPad's.
    private static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// The window takes the theme's colours unless the user keeps it light, dark or with the
    /// system. Turning matching off starts on the scheme opposite the theme's, so the change shows.
    @ViewBuilder private var windowRows: some View {
        let matches = Binding {
            windowTheme == .auto
        } set: { on in
            windowTheme = on ? .auto : (ThemeCatalog.theme(named: theme).isLight ? .dark : .light)
        }
        Toggle(isOn: matches.animation(DS.Motion.micro)) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Window Matches Theme")
                Text(Self.isPhone ? "Bars and key bar in the theme's colours" : "Sidebar, toolbar and key bar in the theme's colours")
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
            Stepper(value: $fontSize, in: TerminalPreferences.fontSizeRange, step: TerminalPreferences.fontSizeStep) {
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
            NavigationLink("Key Bar Profiles", value: SettingsPage.keyBarProfiles)
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
    #if os(macOS)
    @AppStorage(MenuBarAgents.key) private var showsMenuBarAgents = false
    #endif

    var body: some View {
        NotificationPrefsSection()
        #if os(macOS)
        Section {
            Toggle(isOn: $showsMenuBarAgents) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agents in the Menu Bar")
                    Text("The most urgent state, and the agents that need you")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .accessibilityIdentifier("settings-menu-bar-agents")
            .settingAnchor("menu-bar-agents")
        }
        #endif
        Section {
            Toggle(isOn: $bellBorder) { ConfigLabel("Flash Border on Bell", key: "bell-features = border") }
                .settingAnchor("bell-features")
        } header: {
            Text("Bell")
        }
    }
}

private struct AboutSection: View {
    #if os(macOS)
    private let updater = AppUpdater.shared
    #endif
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        Section {
            #if os(macOS)
            if updater.isAvailable {
                LabeledContent("Version") {
                    HStack(spacing: DS.Space.s) {
                        Text(version).foregroundStyle(DS.Palette.textSecondary)
                        Button(AppUpdater.checkTitle) { updater.checkForUpdates() }
                            .buttonStyle(.formAction)
                            .disabled(!updater.canCheckForUpdates)
                            .accessibilityIdentifier("settings-check-for-updates")
                    }
                }
                .settingAnchor("version")
                @Bindable var updater = updater
                Toggle("Check for Updates Automatically", isOn: $updater.checksAutomatically)
                    .accessibilityIdentifier("settings-updates-check-automatically")
                    .settingAnchor("updates-check-automatically")
                Toggle("Download and Install Updates Automatically", isOn: $updater.downloadsAutomatically)
                    .disabled(!updater.allowsAutomaticDownloads)
                    .accessibilityIdentifier("settings-updates-download-automatically")
                    .settingAnchor("updates-download-automatically")
            } else {
                LabeledContent("Version", value: version)
                    .settingAnchor("version")
            }
            #else
            LabeledContent("Version", value: version)
                .settingAnchor("version")
            #endif
            NavigationLink("Acknowledgements", value: SettingsPage.acknowledgements)
                .settingAnchor("acknowledgements")
            if let privacy = URL(string: "https://\(Brand.webDomain)/privacy/") {
                Link("Privacy Policy", destination: privacy)
                    .settingAnchor("privacy-policy")
            }
            if let support = URL(string: "https://\(Brand.webDomain)/support/") {
                Link("Support", destination: support)
                    .settingAnchor("support")
            }
        } header: {
            PaneSectionTitle("About")
        }
    }
}

#if os(macOS)
/// The panes, selected in the theme's accent whether or not the window is active; ↑ and ↓ move
/// through them.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane
    private static let rowHeight: CGFloat = 32
    /// SF Symbols fill more of their frame than logos do.
    private static let glyphShare: CGFloat = 0.82

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(SettingsPane.allCases) { pane in
                    let isSelected = pane == selection
                    Button { selection = pane } label: {
                        HStack(spacing: DS.Space.s) {
                            TileArtwork(size: ProgramTile.rowSize, isSelected: isSelected) { glyphSize, _ in
                                Image(systemName: pane.systemImage)
                                    .font(.system(size: glyphSize * Self.glyphShare, weight: .medium))
                                    .frame(width: glyphSize, height: glyphSize)
                            }
                            Text(pane.title)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, DS.Space.s)
                        .frame(height: Self.rowHeight)
                    }
                    .buttonStyle(.sidebarRow(selected: isSelected))
                    .accessibilityLabel(pane.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("settings-pane-\(pane.rawValue)")
                }
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs)
        }
        .scrollIndicators(.never)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand(perform: move)
    }

    private func move(_ direction: MoveCommandDirection) {
        let panes = SettingsPane.allCases
        guard let index = panes.firstIndex(of: selection) else { return }
        switch direction {
        case .up where index > panes.startIndex: selection = panes[index - 1]
        case .down where index < panes.endIndex - 1: selection = panes[index + 1]
        default: break
        }
    }
}

#if os(macOS)
private extension View {
    /// Rows pass under the title bar's edge, never under the title: the band behind the title is
    /// the page's own colour, with a hairline once the rows have scrolled beneath it.
    func titleBarEdge() -> some View {
        modifier(TitleBarEdge())
    }
}

/// The title bar's height over the form, and how far the form's own top sits below the window's:
/// a band laid inside a view that ignores the safe area would read no inset at all.
private nonisolated struct TitleBand: Equatable, Sendable {
    var height: CGFloat = 0
    var formTop: CGFloat = 0
}

private struct TitleBarEdge: ViewModifier {
    @State private var isScrolled = false
    @State private var band = TitleBand()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y + $0.contentInsets.top > 0 }) { _, scrolled in
                isScrolled = scrolled
            }
            .onGeometryChange(for: TitleBand.self) { proxy in
                let formTop = proxy.frame(in: .global).minY
                // Laid out under the title bar, the form's top is its window's; laid out below
                // it, the band fills the space above.
                return TitleBand(height: formTop > 0 ? formTop : proxy.safeAreaInsets.top, formTop: formTop)
            } action: { band = $0 }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(DS.Palette.groupedPage)
                    .overlay(alignment: .bottom) {
                        Hairline(style: DS.Palette.separator)
                            .opacity(isScrolled ? 1 : 0)
                            .animation(DS.Motion.micro, value: isScrolled)
                    }
                    .frame(height: band.height)
                    .offset(y: -band.formTop)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
#endif

/// Where the keyboard is in the Mac's Settings sidebar.
private enum SettingsFocus: Hashable {
    case search, panes
}

/// The sidebar's search (System Settings': above the panes, under the traffic lights).
private struct SettingsSearchField: View {
    @Binding var query: String
    var focus: FocusState<SettingsFocus?>.Binding

    var body: some View {
        HStack(spacing: DS.Space.row) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DS.Palette.textTertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused(focus, equals: .search)
                .onKeyPress(.escape) {
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: 28)
        .fieldSurface(isFocused: focus.wrappedValue == .search)
    }
}
#endif

/// A section named like its pane: the Mac's titlebar already says it, iOS's one form needs it.
struct PaneSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        #if os(iOS)
        Text(title)
        #endif
    }
}

/// Four of a theme's ANSI colours: red, green, blue, yellow.
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
                .background(theme.background, in: .rect(cornerRadius: DS.Radius.chip, style: .continuous))
                .hairlineBorder(RoundedRectangle.rounded(DS.Radius.chip), style: DS.Palette.hairline)
            ThemeSwatches(theme: theme, size: 8)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Key bar profiles

/// The key bar profiles, shown as key caps in bar order.
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
        // The pinned keys are the same in every profile; the profile's keys, then the favourites, follow.
        let spine = ["esc", "ctrl", "tab", "enter"].map { AnyView(KeyCap($0)) }
        var seen = KeyCatalog.pinnedIDs
        let wing = (profile.keys + FavouriteKeys.shared.keys).filter { seen.insert($0.id).inserted }.map { key -> AnyView in
            if let title = key.title {
                return AnyView(KeyCap(title))
            }
            return AnyView(Image(systemName: key.symbol ?? "questionmark").font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(DS.Palette.raised, in: .rect(cornerRadius: DS.Radius.chip, style: .continuous))
                .hairlineBorder(RoundedRectangle.rounded(DS.Radius.chip), style: DS.Palette.separator))
        }
        return spine + wing
    }
}

private struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                ack("Ghostty", "MIT · terminal core (libghostty-vt), split, overlay and palette designs")
                ack("JetBrains Mono", "SIL Open Font License 1.1 · terminal font")
                ack("Nerd Fonts", "MIT and per-icon-set licenses · symbols in the terminal font")
                ack("iTerm2-Color-Schemes", "MIT · terminal themes, as bundled by Ghostty")
                ack("Orca", "MIT · key bar and reconnect behaviour")
                ack("Warp UI framework", "MIT · Copyright (C) 2020-2026 Denver Technologies, Inc. · the “working” shimmer")
            }
            Section {
                ack("Git logo", "Jason Long · CC BY 3.0 · creativecommons.org/licenses/by/3.0")
                ack("Neovim logo", "Jason Long · CC BY 3.0 · creativecommons.org/licenses/by/3.0")
                ack("Ruby logo", "© 2006 Yukihiro Matsumoto · CC BY-SA 2.5 · creativecommons.org/licenses/by-sa/2.5 · cropped to the gem")
                ack("tmux logo", "Copyright (c) 2015, Jason Long · ISC License: Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies. THE SOFTWARE IS PROVIDED \"AS IS\" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE. Drawn in one colour.")
                ack("Helix logo", "@jakenvac · Mozilla Public License 2.0 · source: github.com/helix-editor/helix")
                ack("btop logo", "Aristocratos · Apache License 2.0 · github.com/aristocratos/btop")
                ack("Emacs logo", "Copyright (C) 2015-2026 Free Software Foundation, Inc. · Nicolas Petton · GNU General Public License v3 or later · unmodified; source: git.savannah.gnu.org/cgit/emacs.git")
                ack("htop logo", "htop authors · GNU General Public License v2 or later · unmodified; source: github.com/htop-dev/htop")
                ack("pi logo", "Copyright (c) 2025 Mario Zechner · MIT License: Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. Unmodified; source: github.com/earendil-works/pi")
                ack("Zig logo", "Zig Software Foundation · CC BY-SA 4.0 · creativecommons.org/licenses/by-sa/4.0 · unmodified; source: github.com/ziglang/logo")
                ack("Yarn logo", "The Yarn project · CC BY 4.0 · creativecommons.org/licenses/by/4.0 · unmodified; source: github.com/yarnpkg/assets")
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
            Section {
                NavigationLink("Open-Source Licenses") { LicenseNoticesView() }
                    .accessibilityIdentifier("ack-open-source-licenses")
                    .chromeRows()
            } footer: {
                Text("Full licence texts for the open-source code inside the app and its host helper.")
            }
        }
        .formStyle(.grouped)
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

/// The generated third-party notices (`cargo xtask notices`), as bundled.
private struct LicenseNoticesView: View {
    @State private var text = ""

    var body: some View {
        NativeTextPreview(text: text, numbered: false)
            .navigationTitle("Open-Source Licenses")
            .task {
                guard text.isEmpty,
                      let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") else { return }
                text = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
            }
    }
}
