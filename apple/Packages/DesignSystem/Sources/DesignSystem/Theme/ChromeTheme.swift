import SwiftUI

/// Puts a window's (or a sheet's, or a Settings window's) chrome on the terminal theme: the theme
/// and its `ChromePalette` in the environment and the window scheme (Ghostty `window-theme`).
/// The ink and tint go on content (`chromeContent()`), never above a toolbar: bar items keep the
/// system's monochrome look and their disabled state.
private struct ChromeThemeModifier: ViewModifier {
    let theme: TerminalTheme
    let windowTheme: TerminalPreferences.WindowTheme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let chrome = ChromePalette.cached(theme: theme, scheme: requestedScheme)
        content
            .environment(\.terminalTheme, theme)
            .environment(\.chrome, chrome)
            .preferredColorScheme(preferredScheme(chrome))
    }

    /// The scheme the user asked the window to take, nil for Match Theme.
    private var requestedScheme: ColorScheme? {
        switch windowTheme {
        case .auto: nil
        case .system: colorScheme
        case .light: .light
        case .dark: .dark
        }
    }

    private func preferredScheme(_ chrome: ChromePalette) -> ColorScheme? {
        windowTheme == .system ? nil : chrome.scheme
    }
}

public extension View {
    /// The window's chrome follows `theme` (and `windowTheme`): apply once at every window, sheet
    /// and Settings root.
    func chromeTheme(_ theme: TerminalTheme, windowTheme: TerminalPreferences.WindowTheme = .auto) -> some View {
        modifier(ChromeThemeModifier(theme: theme, windowTheme: windowTheme))
    }

    /// Views drawn on the terminal itself (pane headers, banners over the grid): the theme's own
    /// chrome and scheme, whatever the window's, so they read on the terminal's background. The
    /// scheme goes into the environment only: a preferred scheme would restyle the whole window.
    func terminalSurfaceChrome() -> some View {
        modifier(TerminalSurfaceChrome())
    }

    /// Content on the chrome: the theme's three text levels as the hierarchical foreground styles
    /// (so `.primary`, `.secondary` and `.tertiary` below are the theme's ink, not the system's
    /// greys) and the accent as the tint. Apply under a view's `.toolbar`, never above it.
    func chromeContent() -> some View {
        modifier(ChromeContentModifier())
    }

    /// A grouped list or form on the chrome's grouped page, instead of the system's black or grey,
    /// with the theme's ink (`chromeContent()`).
    func chromeGrouped() -> some View {
        scrollContentBackground(.hidden)
            .background(DS.Palette.groupedPage, ignoresSafeAreaEdges: .all)
            .chromeContent()
    }

    /// Rows on the chrome's grouped row surface; apply to each section of a `chromeGrouped()` list.
    func chromeRows() -> some View {
        listRowBackground(Rectangle().fill(DS.Palette.groupedRow))
    }

    /// A chrome surface behind the view out to the window's edges, under the software keyboard
    /// and key bar too: they float over it, and a background that stops at the keyboard's safe
    /// area leaves the window's own black or white there.
    func chromeBackground(_ style: ChromeStyle) -> some View {
        background { Rectangle().fill(style).ignoresSafeArea() }
    }

    /// A sheet's own opaque background on the chrome (Mac sheets, iPad form sheets, iPhone page
    /// sheets).
    func chromeSheetBackground() -> some View {
        modifier(ResolvedChromeBackground(token: .groupedPage, place: .sheet))
    }

    #if os(iOS)
    /// An opaque navigation bar on a chrome surface.
    func chromeBarBackground(_ token: ChromeStyle.Token) -> some View {
        modifier(ResolvedChromeBackground(token: token, place: .navigationBar))
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }
    #endif
}

/// Bar and sheet backgrounds are handed to UIKit only when their value changes, and a token is
/// equal under every theme: these get the resolved colour so a theme change reaches them.
private struct ResolvedChromeBackground: ViewModifier {
    enum Place { case sheet, navigationBar }
    let token: ChromeStyle.Token
    let place: Place
    @Environment(\.chrome) private var chrome

    @ViewBuilder func body(content: Content) -> some View {
        switch place {
        // Painted by the content too: opaque from the first frame of the presentation, before
        // (and wherever) the system's glass would show what is behind.
        case .sheet:
            content
                .background(chrome.color(token), ignoresSafeAreaEdges: .all)
                .presentationBackground(chrome.color(token))
        #if os(iOS)
        case .navigationBar: content.toolbarBackground(chrome.color(token), for: .navigationBar)
        #else
        case .navigationBar: content
        #endif
        }
    }
}

private struct TerminalSurfaceChrome: ViewModifier {
    @Environment(\.terminalTheme) private var theme

    func body(content: Content) -> some View {
        content
            .environment(\.chrome, ChromePalette.cached(theme: theme))
            .environment(\.colorScheme, theme.colorScheme)
    }
}

private struct ChromeContentModifier: ViewModifier {
    @Environment(\.chrome) private var chrome

    func body(content: Content) -> some View {
        content
            .foregroundStyle(chrome.text, chrome.textSecondary, chrome.textTertiary)
            .tint(chrome.accentColor)
    }
}

public extension ChromePalette {
    /// The palette for the user's settings, for UIKit and AppKit views that cannot read the
    /// environment (the key bar, layer-backed marks). `systemScheme` is the trait collection's
    /// style, used when `window-theme` is System.
    static func fromPreferences(systemScheme: ColorScheme? = nil, defaults: UserDefaults = .standard) -> ChromePalette {
        let theme = ThemeCatalog.theme(named: defaults.string(forKey: TerminalPreferences.Key.theme) ?? TerminalPreferences.Default.theme)
        let windowTheme = defaults.string(forKey: TerminalPreferences.Key.windowTheme).flatMap(TerminalPreferences.WindowTheme.init) ?? .auto
        let scheme: ColorScheme? = switch windowTheme {
        case .auto: nil
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
        return ChromePalette(theme: theme, scheme: scheme)
    }
}

/// Reads the user's theme settings and applies `chromeTheme`: for roots that are not handed the
/// theme (the Mac Settings window, extra scenes).
public struct ThemedRoot<Content: View>: View {
    @AppStorage(TerminalPreferences.Key.theme) private var themeName = TerminalPreferences.Default.theme
    @AppStorage(TerminalPreferences.Key.windowTheme) private var windowTheme = TerminalPreferences.WindowTheme.auto
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content.chromeTheme(ThemeCatalog.theme(named: themeName), windowTheme: windowTheme)
    }
}
