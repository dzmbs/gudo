import SwiftUI
import TerminalCore
import TerminalRenderer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Links tapped (iPad, iPhone) or ⌘-clicked (Mac) in a pane: OSC 8 hyperlinks and URLs or paths
/// printed as text.
///
/// - A sign-in for a program on a remote host (`SignInLink`): the system's sign-in sheet with
///   the callback forwarded to the host, or the in-app browser typing the code it shows.
/// - A dev server's URL (`localhost`, `127.0.0.1`, `[::1]`, `*.localhost`, or the host's own
///   address on a port it listens on) opens in the in-app browser, through a forward when the
///   pane is on a remote host, so it shows what the host serves.
/// - A path opens in the editor at its `:line:col` (a host's pane), or in the Mac's default app
///   (this Mac's pane).
/// - Any other URL: the Mac's default browser; on iPad and iPhone, Safari or the in-app browser
///   as the user chose the first time (Settings ▸ Terminal ▸ Links).
@MainActor
enum PaneLinks {
    static func attach(to pane: Pane, workspace: Workspace) {
        let id = pane.id
        pane.view.onOpenLink = { [weak workspace, weak pane] link in
            guard let workspace, let pane else { return }
            open(link, from: pane, in: workspace)
        }
        pane.view.onHoverLink = { [weak workspace] link in
            guard let workspace else { return }
            let text = link.map { $0.kind == .path ? $0.text : $0.target }
            if workspace.notices[id, default: PaneNotice()].hoveredURL != text {
                workspace.notices[id, default: PaneNotice()].hoveredURL = text
            }
        }
    }

    static func open(_ link: TerminalLink, from pane: Pane, in workspace: Workspace) {
        guard let window = ActiveWindow.model(for: workspace) else { return }
        switch link.kind {
        case .path:
            let directory = pane.workingDirectory.isEmpty ? pane.foreground()?.directory : pane.workingDirectory
            let path = link.resolvedPath(relativeTo: directory)
            window.open(DetectedLink(
                kind: .path, text: link.text, line: 0, target: path, targetLine: link.line, targetColumn: link.column))
        case .url:
            guard let url = URL(string: link.target) else { return }
            if workspace.isRemote, let hostId = workspace.hostId, let signIn = SignInLink(url) {
                // A sign-in for a program on the host (`codex login`'s URL, Claude's printed one).
                window.signIn(url, signIn, hostId: hostId, pane: pane.id.rawValue)
            } else if window.isDevServerURL(url) {
                Task { await window.openURL(link.target) }
            } else if url.scheme == "http" || url.scheme == "https" {
                openWebLink(url, window: window, from: pane)
            } else if !workspace.isRemote || HostLinks.mayOpenExternally(url) {
                // mailto:, ssh:, …: whatever the system opens them with.
                openExternally(url)
            }
        }
    }

    private static func openWebLink(_ url: URL, window: WindowModel, from pane: Pane) {
        #if os(macOS)
        // ⌘-click: the default browser, as in Ghostty.
        openExternally(url)
        #else
        switch LinkOpening.current {
        case .safari: openExternally(url)
        case .inApp: window.showInBrowser(url)
        case .ask: ask(url, window: window, from: pane)
        }
        #endif
    }

    static func openExternally(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    #if os(iOS)
    /// The first web link: where links go from now on (Settings can change it).
    private static func ask(_ url: URL, window: WindowModel, from pane: Pane) {
        let sheet = UIAlertController(
            title: "Open Links in Safari or Here?",
            message: "Links you tap in a terminal will open there from now on. You can change this in Settings.",
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "In-App Browser", style: .default) { _ in
            LinkOpening.current = .inApp
            window.showInBrowser(url)
        })
        sheet.addAction(UIAlertAction(title: "Safari", style: .default) { _ in
            LinkOpening.current = .safari
            openExternally(url)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let view = pane.view
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(origin: view.lastTapLocation ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY), size: .zero)
        }
        var presenter = view.window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(sheet, animated: true)
    }
    #endif
}

/// Where web links tapped in a terminal open on iPad and iPhone.
enum LinkOpening: String, CaseIterable, Identifiable {
    case ask, safari, inApp
    var id: String { rawValue }

    static let key = "terminalLinksOpenIn"

    /// `-resetLinkOpening` (UI tests): forget the choice, so the first link asks again.
    private static let resetForTests: Void = {
        if ProcessInfo.processInfo.arguments.contains("-resetLinkOpening") { UserDefaults.standard.removeObject(forKey: key) }
    }()

    static var current: LinkOpening {
        get {
            _ = resetForTests
            return UserDefaults.standard.string(forKey: key).flatMap(LinkOpening.init) ?? .ask
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .ask: "Ask"
        case .safari: "Safari"
        case .inApp: "In-App Browser"
        }
    }
}

/// Settings ▸ Terminal ▸ Links (iPad, iPhone): where web links open.
struct LinksSettingsSection: View {
    @AppStorage(LinkOpening.key) private var opening = LinkOpening.ask

    var body: some View {
        #if os(iOS)
        Section {
            Picker("Open Web Links In", selection: $opening) {
                ForEach(LinkOpening.allCases) { Text($0.title).tag($0) }
            }
            .settingAnchor("open-web-links")
        } header: {
            Text("Links")
        } footer: {
            Text("Dev server links (localhost and the host's ports) always open in the in-app browser.")
        }
        #endif
    }
}

extension WindowModel {
    /// A URL a dev server on the window's host (or this Mac) printed: loopback names, the
    /// `*.localhost` names browsers resolve to loopback, or the host's own address (a LAN or
    /// Tailscale IP, its name) on a port the host listens on.
    func isDevServerURL(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        if Self.isLoopback(host) { return true }
        guard workspace?.isRemote == true, let port = url.port, ports.ports.contains(where: { $0.port == UInt16(port) }) else { return false }
        return host == ports.hostName.lowercased() || Self.isPrivateAddress(host) || !host.contains(".") || host.hasSuffix(".local")
            || ports.ports.contains { $0.url.flatMap { URL(string: $0)?.host()?.lowercased() } == host }
    }

    nonisolated static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" || host.hasPrefix("127.")
    }

    /// RFC 1918, CGNAT (Tailscale's 100.64/10) and IPv6 unique-local addresses.
    nonisolated static func isPrivateAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        let v6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return v6.hasPrefix("fd") || v6.hasPrefix("fc")
    }

    /// A web page in the in-app browser.
    func showInBrowser(_ url: URL) {
        browserURL = url
        if sheet != .browser { sheet = .browser }
    }
}
