import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A light theme and a dark theme that follow the system's appearance (Ghostty's
/// the system's light/dark choice writes `theme`, so everything that reads the theme (terminals,
/// chrome, key bar) follows without knowing about the pair.
enum ThemePair {
    static let enabledKey = "theme-pair"
    static let lightKey = "theme-light"
    static let darkKey = "theme-dark"
    static let defaultLight = "iTerm2 Solarized Light"
    static var defaultDark: String { TerminalPreferences.Default.theme }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The theme for the system's current appearance, nil while the pair is off.
    static func theme(systemIsDark: Bool, defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        let key = systemIsDark ? darkKey : lightKey
        return defaults.string(forKey: key) ?? (systemIsDark ? defaultDark : resolvedDefaultLight)
    }

    /// A light theme that is bundled: Solarized Light under one of its names, else the first light theme.
    static var resolvedDefaultLight: String {
        let all = ThemeCatalog.all
        for name in [defaultLight, "Builtin Solarized Light", "Builtin Light"] where all.contains(where: { $0.name == name }) {
            return name
        }
        return all.first(where: \.isLight)?.name ?? TerminalPreferences.Default.theme
    }

    /// Writes `theme` for the system's appearance when the pair is on.
    static func apply(systemIsDark: Bool) {
        guard let name = theme(systemIsDark: systemIsDark) else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: TerminalPreferences.Key.theme) != name {
            defaults.set(name, forKey: TerminalPreferences.Key.theme)
        }
    }

    /// The system's own appearance: not the window's, which `window-theme` overrides.
    @MainActor static var systemIsDark: Bool {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return (scene?.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .dark
        #else
        return NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #endif
    }
}

/// Follows the system's appearance for the theme pair: at launch, when the app comes forward,
/// and when the system switches (the scene's traits on iOS, the interface-theme notification on
/// the Mac).
struct ThemePairFollower: ViewModifier {
    @AppStorage(ThemePair.enabledKey) private var enabled = false
    @AppStorage(ThemePair.lightKey) private var light = ThemePair.resolvedDefaultLight
    @AppStorage(ThemePair.darkKey) private var dark = ThemePair.defaultDark
    @Environment(\.scenePhase) private var scenePhase
    @State private var observer = SystemAppearanceObserver()

    func body(content: Content) -> some View {
        content
            .onAppear {
                observer.start { ThemePair.apply(systemIsDark: $0) }
                follow()
            }
            .onChange(of: enabled) { _, _ in follow() }
            .onChange(of: light) { _, _ in follow() }
            .onChange(of: dark) { _, _ in follow() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { follow() } }
    }

    private func follow() {
        ThemePair.apply(systemIsDark: ThemePair.systemIsDark)
    }
}

/// Calls back when the system's light/dark appearance changes.
@MainActor
final class SystemAppearanceObserver {
    private var started = false
    #if os(iOS)
    private var registration: (any UITraitChangeRegistration)?
    #else
    private var token: (any NSObjectProtocol)?
    #endif

    func start(_ changed: @escaping @MainActor (Bool) -> Void) {
        guard !started else { return }
        started = true
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (scene: UIWindowScene, _: UITraitCollection) in
            changed(scene.traitCollection.userInterfaceStyle == .dark)
        }
        #else
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            // The app's appearance updates a moment after the notification.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                changed(ThemePair.systemIsDark)
            }
        }
        #endif
    }
}

/// Settings rows: the switch, then the light and the dark theme, each opening the picker.
struct ThemePairRows<Picker: View>: View {
    @AppStorage(ThemePair.enabledKey) private var enabled = false
    @AppStorage(ThemePair.lightKey) private var light = ThemePair.resolvedDefaultLight
    @AppStorage(ThemePair.darkKey) private var dark = ThemePair.defaultDark
    let picker: (Binding<String>) -> Picker

    var body: some View {
        Toggle(isOn: $enabled.animation(DS.Motion.quick)) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Follow Light and Dark Mode")
                Text("A light theme and a dark theme, switched with the system")
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .accessibilityIdentifier("settings-theme-pair")
        .settingAnchor("theme-pair")
        if enabled {
            row("Light Theme", selection: $light, id: "theme-light")
            row("Dark Theme", selection: $dark, id: "theme-dark")
        }
    }

    private func row(_ title: String, selection: Binding<String>, id: String) -> some View {
        NavigationLink {
            picker(selection)
        } label: {
            HStack {
                Text(title)
                Spacer()
                ThemeSwatchTile(theme: ThemeCatalog.theme(named: selection.wrappedValue))
                Text(selection.wrappedValue).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
            }
        }
        .accessibilityIdentifier("settings-\(id)")
        .settingAnchor(id)
    }
}

/// An "Aa" tile in a theme's own background and foreground.
struct ThemeSwatchTile: View {
    let theme: TerminalTheme

    var body: some View {
        Text("Aa")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.foreground)
            .frame(width: 26, height: 18)
            .background(theme.background, in: .rect(cornerRadius: DS.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
