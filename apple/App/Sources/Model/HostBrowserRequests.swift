import DesignSystem
import Foundation
import HostKit
import PaneLayout
import GudoCore

extension AppModel {
    func browserPush(_ hostId: String, _ push: BrowserPush) {
        // A guest's connection never asks for these; a host that sends them anyway is ignored.
        guard hosts.record(hostId)?.isGuest != true else {
            Self.log.error("guest host \(hostId, privacy: .public) sent a browser request")
            if case .call(let id, _, _, _) = push {
                (hosts.connection(hostId) as? DaemonConnection)?.browser.answer(id, .failure(BrowserCallError("Not allowed.")))
            }
            return
        }
        switch push {
        case .open(let paneId, let text):
            guard let url = URL(string: text), HostLinks.mayOpen(url), let window = window(forHost: hostId) else {
                Self.log.error("host \(hostId, privacy: .public) pane \(paneId) asked to open a URL that is not a web page")
                return
            }
            Self.log.info("host \(hostId, privacy: .public) pane \(paneId) opens a URL")
            window.openFromHost(url, hostId: hostId, pane: paneId)
        case .call(let id, let paneId, let tool, let args):
            let session = (hosts.connection(hostId) as? DaemonConnection)?.browser
            BrowserAgent.shared.run(id, tool: tool, args: args, pane: HostPane(hostId: hostId, pane: PaneId(paneId)), app: self) { result in
                session?.answer(id, result)
            }
        case .callClosed(let id):
            BrowserAgent.shared.cancel(id)
        }
    }

    /// The active window when it has the host open, else one that has.
    func window(forHost hostId: String) -> WindowModel? {
        let windows = openWindows.filter { !$0.isPresentation }
        if let active = ActiveWindow.model, !active.isClosed, active.workspace(ofGroup: hostId) != nil { return active }
        return windows.first { $0.workspace(ofGroup: hostId) != nil } ?? ActiveWindow.model ?? windows.first
    }
}

/// What a host may make this device open. A host is a remote machine, possibly someone
/// else's: it opens web pages only, never this device's files (which its agent could then
/// read through the browser tools) or another app's links.
nonisolated enum HostLinks {
    static func mayOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return url.host()?.isEmpty == false
    }

    /// Never a `file:` URL: it names a path on the host, and here would open this device's file or app.
    static func mayOpenExternally(_ url: URL) -> Bool {
        url.scheme?.lowercased() != "file"
    }
}

extension WindowModel {
    /// A sign-in goes to the system's sign-in sheet; anything else to a browser leaf beside the pane.
    func openFromHost(_ url: URL, hostId: String, pane: UInt64) {
        if let link = SignInLink(url) {
            signIn(url, link, hostId: hostId, pane: pane)
        } else {
            openBrowser(url, beside: HostPane(hostId: hostId, pane: PaneId(pane)))
        }
    }

    /// A loopback sign-in gets that port here; one that shows a code opens in the in-app browser,
    /// which types the code into the pane.
    func signIn(_ url: URL, _ link: SignInLink, hostId: String, pane: UInt64) {
        switch link {
        case .loopback(let port, let path):
            HostSignIn.start(url, port: port, path: path, hostId: hostId, in: self)
        case .pastedCode:
            showInBrowser(url)
            // The host's own store: its sign-in never rides on the user's sessions.
            browserHost = hostId
            browserSignInPane = (hostId, pane)
        }
    }

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
