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
