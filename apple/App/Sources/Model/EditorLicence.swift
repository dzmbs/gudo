import Foundation
import GudoCore

/// The user's own acceptance of Microsoft's terms for VS Code on a host: the Visual Studio Code
/// licence (the `code` CLI the host downloads from Microsoft), the VS Code Server licence
/// (`serve-web` and the tunnel) and the Microsoft Privacy Statement. Accepted once per host in
/// on the Mac has its own terms and does not ask here.
@MainActor
struct EditorLicence {
    /// Visual Studio Code licence (covers the `code` CLI).
    static let vscodeLicenseURL = URL(string: vscodeLicenseUrl())!
    /// VS Code Server licence (covers `code serve-web` and Remote Tunnels).
    static let serverLicenseURL = URL(string: vscodeServerLicenseUrl())!
    /// Microsoft Privacy Statement.
    static let privacyURL = URL(string: microsoftPrivacyUrl())!

    static let key = "editor.vscodeLicenceAccepted"
    private static var didReset = false

    var defaults: UserDefaults = .standard

    /// When the user accepted for this host, or nil.
    func acceptedAt(host: String) -> Date? {
        guard let stamps = defaults.dictionary(forKey: Self.key) as? [String: Double], let at = stamps[host] else { return nil }
        return Date(timeIntervalSince1970: at)
    }

    func isAccepted(host: String) -> Bool { acceptedAt(host: host) != nil }

    /// Records the user's acceptance for this host (only ever from the sheet's Accept button).
    func accept(host: String, at date: Date = .now) {
        var stamps = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        stamps[host] = date.timeIntervalSince1970
        defaults.set(stamps, forKey: Self.key)
    }

    /// Forgets the acceptance for this host: the sheet comes back next time.
    func withdraw(host: String) {
        var stamps = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        stamps[host] = nil
        defaults.set(stamps, forKey: Self.key)
    }

    /// UI tests (`-editorLicenceReset YES`): every host asks again.
    /// Once per launch: every editor pane makes its own source.
    static func resetForTestsIfAsked() {
        guard !didReset, UserDefaults.standard.bool(forKey: "editorLicenceReset") else { return }
        didReset = true
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Where vscode.dev is. UI tests point it at a local stand-in (`-testTunnelWebBase
/// http://127.0.0.1:<port>`) so nothing is downloaded.
nonisolated enum TunnelWeb {
    static let origin = "https://vscode.dev"

    /// The page for a host's tunnel address: vscode.dev only. The host names the address, and
    /// any other page would show in the editor's place.
    static func url(_ webURL: String, base: String? = LaunchArguments().string(forKey: "testTunnelWebBase")) -> URL? {
        guard webURL.hasPrefix(origin + "/") || webURL.hasPrefix("https://insiders.vscode.dev/") else { return nil }
        guard let base, !base.isEmpty, webURL.hasPrefix(origin + "/") else { return URL(string: webURL) }
        return URL(string: base + webURL.dropFirst(origin.count))
    }

    /// The desktop app's link for a tunnel, or nil for anything else the host sends (other
    /// `vscode:` links reach extensions' URI handlers).
    static func desktopURI(_ text: String) -> URL? {
        guard text.hasPrefix("vscode://vscode-remote/tunnel+") else { return nil }
        return URL(string: text)
    }
}
