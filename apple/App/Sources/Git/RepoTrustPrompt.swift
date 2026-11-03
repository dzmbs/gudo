import CryptoKit
import Foundation
import HostKit
import GudoCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Asks the owner before a repository's own setup or teardown commands (`.gudo.json`) run for
/// the first time or after they changed: a clone must not run commands just because a task
/// started in it. The daemon keeps the trust; declining only skips the commands this time.
@MainActor
enum RepoTrustPrompt {
    enum Moment {
        case setup
        case teardown
    }

    /// Returns whether the commands will run; a nil `ask` means nothing needs trusting. Guests
    /// are never asked: they cannot trust a host's repositories, and the commands don't run for them.
    @discardableResult
    static func confirm(_ ask: RepoHooksTrust?, moment: Moment, api: any DaemonRepoTrustAPI) async -> Bool {
        guard let ask else { return true }
        let text = text(for: ask, moment: moment)
        guard await present(title: text.title, message: text.message) else { return false }
        do {
            try await api.repoTrust(repo: ask.repo, hash: ask.hash)
            return true
        } catch {
            return false
        }
    }

    static func text(for ask: RepoHooksTrust, moment: Moment) -> (title: String, message: String) {
        let name = (ask.repo as NSString).lastPathComponent
        let title = switch moment {
        case .setup: "Run Setup Commands for \(name)?"
        case .teardown: "Run Teardown Commands for \(name)?"
        }
        var lines: [String] = []
        if let setup = ask.setup { lines.append("Setup: \(setup)") }
        if let teardown = ask.teardown { lines.append("Teardown: \(teardown)") }
        let message = "\(name) asks to run these commands on the host:\n\n"
            + lines.joined(separator: "\n")
            + "\n\nRun them only if you trust this repository. You'll be asked again if they change."
        return (title, message)
    }

    /// Asks before a script from the repository's own configuration runs for the first time on
    /// this device or after its command changed. Returns whether it may run.
    static func confirm(script name: String, command: String, repo: String, host: String) async -> Bool {
        if RepoScriptTrust.isTrusted(command, repo: repo, host: host) { return true }
        let text = text(forScript: name, command: command, repo: repo)
        guard await present(title: text.title, message: text.message) else { return false }
        RepoScriptTrust.trust(command, repo: repo, host: host)
        return true
    }

    static func text(forScript name: String, command: String, repo: String) -> (title: String, message: String) {
        let repoName = (repo as NSString).lastPathComponent
        let message = "\(repoName) defines this command for “\(RepoScriptTrust.visible(name))”:\n\n"
            + RepoScriptTrust.visible(command)
            + "\n\nRun it only if you trust this repository. You'll be asked again if it changes."
        return ("Run “\(RepoScriptTrust.visible(name))” from \(repoName)?", message)
    }

    private static func present(title: String, message: String) async -> Bool {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Don't Run")
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Don't Run", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Run", style: .default) { _ in continuation.resume(returning: true) })
            var presenter = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
            while let next = presenter?.presentedViewController { presenter = next }
            guard let presenter else {
                continuation.resume(returning: false)
                return
            }
            presenter.present(alert, animated: true)
        }
        #endif
    }
}

/// Scripts from a repository's own configuration the user allowed on this device: per host and
/// repository, the SHA-256 of each command, so a changed command is asked about again.
enum RepoScriptTrust {
    static let key = "git.trustedRepoScripts"
    static let maxPerRepo = 32

    static func isTrusted(_ command: String, repo: String, host: String, defaults: UserDefaults = .standard) -> Bool {
        trusted(in: defaults)[scope(repo: repo, host: host)]?.contains(digest(command)) == true
    }

    static func trust(_ command: String, repo: String, host: String, defaults: UserDefaults = .standard) {
        var all = trusted(in: defaults)
        let scope = scope(repo: repo, host: host)
        let hash = digest(command)
        var hashes = (all[scope] ?? []).filter { $0 != hash }
        hashes.append(hash)
        all[scope] = Array(hashes.suffix(maxPerRepo))
        defaults.set(all, forKey: key)
    }

    /// Every control and format character shown as its code, so a command cannot hide what
    /// follows a carriage return or reorder itself with bidi controls.
    static func visible(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            let category = scalar.properties.generalCategory
            guard scalar != "\n", scalar != "\t", category == .control || category == .format else { return String(scalar) }
            return String(format: "\\u{%04X}", scalar.value)
        }.joined()
    }

    private static func trusted(in defaults: UserDefaults) -> [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    private static func scope(repo: String, host: String) -> String { host + "\n" + repo }

    private static func digest(_ command: String) -> String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
