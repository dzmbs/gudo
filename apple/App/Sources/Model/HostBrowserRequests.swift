import DesignSystem
import Foundation
import HostKit
import UnnamedCore

// What a host asks of the app's browser (`proto::browser`): URLs its panes open through
// `BROWSER` (`claude /login`), and browser tools its agents call.

extension AppModel {
    func browserPush(_ hostId: String, _ push: BrowserPush) {
        switch push {
        case .open(let paneId, let text):
            guard let url = URL(string: text), let window = window(forHost: hostId) else { return }
            Self.log.info("host \(hostId, privacy: .public) pane \(paneId) opens a URL")
            window.openFromHost(url, hostId: hostId, pane: paneId)
        case .call(let id, _, let tool, _):
            (hosts.connection(hostId) as? DaemonConnection)?.browser
                .answer(id, .failure(BrowserCallError("\(tool) is not available in this version of the app")))
        case .callClosed:
            break
        }
    }

    /// The window a host's request shows in: the active one when it has the host open, else
    /// one that has.
    func window(forHost hostId: String) -> WindowModel? {
        let windows = openWindows.filter { !$0.isPresentation }
        if let active = ActiveWindow.model, !active.isClosed, active.workspace(ofGroup: hostId) != nil { return active }
        return windows.first { $0.workspace(ofGroup: hostId) != nil } ?? ActiveWindow.model ?? windows.first
    }
}

extension WindowModel {
    /// A URL a program on a host opened: a sign-in in the system's sign-in sheet (its callback
    /// forwarded to the host), a dev server through a forward, anything else in the browser.
    func openFromHost(_ url: URL, hostId: String, pane: UInt64) {
        if let link = SignInLink(url) {
            signIn(url, link, hostId: hostId, pane: pane)
        } else if hostId == currentGroupId, isDevServerURL(url) {
            Task { await openURL(url.absoluteString) }
        } else {
            showInBrowser(url)
        }
    }

    /// A sign-in for a program in `pane` on a host. One that returns to the host's loopback
    /// gets that port here; one that shows a code to paste opens in the in-app browser, which
    /// types the code into the pane when the provider's page shows it.
    func signIn(_ url: URL, _ link: SignInLink, hostId: String, pane: UInt64) {
        switch link {
        case .loopback(let port, let path):
            HostSignIn.start(url, port: port, path: path, hostId: hostId, in: self)
        case .pastedCode:
            showInBrowser(url)
            browserSignInPane = (hostId, pane)
        }
    }

    /// The in-app browser reached the page with the code: it goes into the pane that asked.
    func pastedSignInCode(_ url: URL) -> Bool {
        guard let target = browserSignInPane, let code = SignInLink.pastedCode(from: url),
              let daemon = app.hosts.connection(target.hostId) as? DaemonConnection
        else { return false }
        daemon.type(code, into: target.pane)
        browserURL = nil
        sheet = nil
        toasts.show(Toast("Signed in: the code went to the terminal", systemImage: "checkmark.circle.fill", style: .success))
        return true
    }
}
