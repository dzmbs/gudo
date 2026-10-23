import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The language pages are asked for (Settings ▸ Browser ▸ Language for Websites): sent as
/// `Accept-Language` on the page's own navigations, since WebKit otherwise derives it from the
/// device and sites then guess from the network's country. Empty is the system's.
nonisolated enum WebsiteLanguage {
    static let key = "browserWebsiteLanguage"
    static let defaultTag = "en-US"

    /// Tags offered, by name in English.
    static let tags = [
        "en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "es-419", "it-IT", "pt-BR", "pt-PT", "nl-NL",
        "sv-SE", "da-DK", "nb-NO", "fi-FI", "pl-PL", "cs-CZ", "hu-HU", "ro-RO", "el-GR", "tr-TR",
        "ru-RU", "uk-UA", "sr-RS", "hr-HR", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "hi-IN", "ar-SA", "he-IL",
    ]

    static var current: String {
        UserDefaults.standard.string(forKey: key) ?? defaultTag
    }

    static func name(_ tag: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: tag) ?? tag
    }

    /// `en-US,en;q=0.9`; other languages fall back to English after their own
    /// (`de-DE,de;q=0.9,en;q=0.8`). Nil for the system's.
    static func acceptLanguage(_ tag: String) -> String? {
        guard !tag.isEmpty else { return nil }
        let language = String(tag.prefix { $0 != "-" })
        var parts = [tag]
        if language != tag { parts.append("\(language);q=0.9") }
        if language != "en" { parts.append("en;q=0.8") }
        return parts.joined(separator: ",")
    }
}

/// The country search results are for (Settings ▸ Browser ▸ Search Region). Sites read it from
/// the network address; only search engines take it as a parameter (Google's `gl`, Bing's `cc`).
/// Empty is the engine's own guess.
nonisolated enum SearchRegion {
    static let key = "browserSearchRegion"

    static let codes = [
        "US", "GB", "CA", "AU", "IE", "DE", "AT", "CH", "FR", "ES", "IT", "NL", "SE", "PL", "RS", "HR",
        "BA", "SI", "RU", "UA", "TR", "JP", "KR", "CN", "TW", "IN", "BR", "MX",
    ]

    static var current: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forRegionCode: code) ?? code
    }
}

/// Whether pages take the terminal theme's light or dark appearance (`prefers-color-scheme`)
/// or the device's (Settings ▸ Browser ▸ Websites Follow Theme Appearance).
enum WebsiteAppearance {
    static let key = "browserWebsitesFollowTheme"

    /// The device's own appearance: the window's is the theme's.
    @MainActor static var systemScheme: ColorScheme {
        #if os(iOS)
        UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        #else
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
        #endif
    }
}

/// What a search URL carries besides the query: the interface language and the result region.
nonisolated struct SearchLocale: Hashable, Sendable {
    var language = ""
    var region = ""

    static var current: SearchLocale {
        SearchLocale(language: WebsiteLanguage.current, region: SearchRegion.current)
    }
}
