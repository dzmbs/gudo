import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Sent as `Accept-Language`. Empty is the system's: WebKit sends the preferred languages the
/// way Safari does. A bare `en-US` reads as an unset browser to Google, which then answers in
/// the network country's language.
nonisolated enum WebsiteLanguage {
    static let key = "browserWebsiteLanguage"
    static let defaultTag = ""

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

/// The country search results are for; only search engines take it as a parameter. Empty is the
/// engine's own guess.
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

/// The scheme pages get for `prefers-color-scheme`. Pages without a dark style stay as they are:
/// WebKit has no public way to darken them.
nonisolated enum BrowserAppearance: String, CaseIterable, Identifiable {
    case matchTheme, light, dark

    static let key = "browserAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchTheme: "Match Theme"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    func scheme(theme: ColorScheme) -> ColorScheme {
        switch self {
        case .matchTheme: theme
        case .light: .light
        case .dark: .dark
        }
    }
}

nonisolated struct SearchLocale: Hashable, Sendable {
    var language = ""
    var region = ""

    static var current: SearchLocale {
        SearchLocale(language: WebsiteLanguage.current, region: SearchRegion.current)
    }
}

/// Safari's own product tokens after WebKit's: without them Google and others serve their basic
/// pages for old browsers. An iPad shows desktop pages, as Safari does there.
enum BrowserUserAgent {
    @MainActor static var applicationName: String {
        #if os(iOS)
        applicationName(safariVersion: safariVersion, mobile: UIDevice.current.userInterfaceIdiom == .phone)
        #else
        applicationName(safariVersion: safariVersion, mobile: false)
        #endif
    }

    nonisolated static func applicationName(safariVersion: String, mobile: Bool) -> String {
        mobile ? "Version/\(safariVersion) Mobile/15E148 Safari/604.1" : "Version/\(safariVersion) Safari/605.1.15"
    }

    /// Safari's version is the system's since 26.
    nonisolated static var safariVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
