import Foundation

/// Product naming comes from apple/Brand.xcconfig through the bundle, never from string literals.
nonisolated enum Brand {
    static let isDev = (Bundle.main.object(forInfoDictionaryKey: "BrandIsDev") as? String) == "YES"
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ""
    /// The host daemon's executable name (`gudo-hostd`), bundled and installed on hosts.
    static let daemonBinary = Bundle.main.object(forInfoDictionaryKey: "BrandDaemonBinary") as? String ?? ""
    /// The helper's short command (`gudo pair`, `gudo devices`): a link to the helper.
    static let commandLineTool = Bundle.main.object(forInfoDictionaryKey: "BrandCommandLineTool") as? String ?? ""
    /// The web domain whose `/pair#…` and `/join#…` links open the app (universal links).
    static let webDomain = Bundle.main.object(forInfoDictionaryKey: "BrandWebDomain") as? String ?? ""

    /// What the app was called before, for taking over what that build left on this Mac.
    enum Legacy {
        static let name = "unnamed"
        static let bundleIdPrefix = "dev.unnamed"
    }
}
