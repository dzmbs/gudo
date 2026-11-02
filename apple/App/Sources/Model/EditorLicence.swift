import Foundation
import GudoCore

/// The user's own acceptance of Microsoft's VS Code, VS Code Server and privacy terms, once per
/// host in the editor's first-use sheet. Never assumed: the host downloads the `code` CLI from
/// Microsoft under those terms.
@MainActor
struct EditorLicence {
    /// Covers the `code` CLI.
    static let vscodeLicenseURL = URL(string: vscodeLicenseUrl())!
    /// Covers `code serve-web` and Remote Tunnels.
    static let serverLicenseURL = URL(string: vscodeServerLicenseUrl())!
    static let privacyURL = URL(string: microsoftPrivacyUrl())!

    static let key = "editor.vscodeLicenceAccepted"
    private static var didReset = false

    var defaults: UserDefaults = .standard

    func acceptedAt(host: String) -> Date? {
        guard let stamps = defaults.dictionary(forKey: Self.key) as? [String: Double], let acceptedTime = stamps[host] else { return nil }
        return Date(timeIntervalSince1970: acceptedTime)
    }

    func isAccepted(host: String) -> Bool { acceptedAt(host: host) != nil }

    /// Only ever from the sheet's Accept button.
    func accept(host: String, at date: Date = .now) {
        var stamps = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        stamps[host] = date.timeIntervalSince1970
        defaults.set(stamps, forKey: Self.key)
    }

    func withdraw(host: String) {
        var stamps = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        stamps[host] = nil
        defaults.set(stamps, forKey: Self.key)
    }

    /// `-editorLicenceReset YES`; once per launch, since every editor pane makes its own source.
    static func resetForTestsIfAsked() {
        guard !didReset, UserDefaults.standard.bool(forKey: "editorLicenceReset") else { return }
        didReset = true
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// UI tests point vscode.dev at a local stand-in (`-testTunnelWebBase`) so nothing is downloaded.
nonisolated enum TunnelWeb {
    static let origin = "https://vscode.dev"

    /// vscode.dev only: the host names the address, and any other page would show in the editor's place.
    static func url(_ webURL: String, base: String? = LaunchArguments().string(forKey: "testTunnelWebBase")) -> URL? {
        guard webURL.hasPrefix(origin + "/") || webURL.hasPrefix("https://insiders.vscode.dev/") else { return nil }
        guard let base, !base.isEmpty, webURL.hasPrefix(origin + "/") else { return URL(string: webURL) }
        return URL(string: base + webURL.dropFirst(origin.count))
    }

    /// Nil for anything but a tunnel link: other `vscode:` links reach extensions' URI handlers.
    static func desktopURI(_ text: String) -> URL? {
        guard text.hasPrefix("vscode://vscode-remote/tunnel+") else { return nil }
        return URL(string: text)
    }
}
