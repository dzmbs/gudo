#if os(iOS)
import DesignSystem
import UIKit

/// The key bar's colours. It floats over the terminal, so it takes the terminal theme's own
/// light or dark and ink (not the window's, which `window-theme` may force the other way), and the
/// theme's accent for latched keys (`ChromePalette`).
@MainActor
enum KeyBarTheme {
    private static var cache: (name: String, chrome: ChromePalette)?

    static var chrome: ChromePalette {
        let name = UserDefaults.standard.string(forKey: TerminalPreferences.Key.theme) ?? TerminalPreferences.Default.theme
        if let cache, cache.name == name { return cache.chrome }
        let chrome = ChromePalette(theme: ThemeCatalog.theme(named: name))
        cache = (name, chrome)
        return chrome
    }

    /// Key labels: the theme's ink (UIKit's `.label` is neutral grey on a tinted terminal).
    static var ink: UIColor { UIColor(chrome.foreground.color) }
    static var accent: UIColor { UIColor(chrome.accent.color) }
    static var style: UIUserInterfaceStyle { chrome.scheme == .light ? .light : .dark }
}
#endif
