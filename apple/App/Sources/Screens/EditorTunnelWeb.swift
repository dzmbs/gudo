import Observation
import os
import SwiftUI
import TerminalCore
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// vscode.dev through a VS Code Remote Tunnel, top-level in a `WKWebView` because vscode.dev
/// refuses framing. Popups (sign-ins, new windows) come up as a sheet whose web view keeps
/// `window.opener`, so the page can close them itself.
@MainActor
@Observable
final class TunnelBrowser: NSObject, WKUIDelegate, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    var popup: Popup?
    private(set) var isLoading = false
    @ObservationIgnored var onLoad: (() -> Void)?
    @ObservationIgnored var onFail: ((String) -> Void)?
    /// The page must be loaded again: its content process ended or the workbench gave up
    /// reconnecting. Passes the reason, for the log.
    @ObservationIgnored var onLost: ((String) -> Void)?

    struct Popup: Identifiable {
        let id = UUID()
        let webView: WKWebView
    }

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "editor")

    /// `phoneLayout`: VS Code's defaults for a phone (`EditorPhoneLayout`).
    init(dataStore: WKWebsiteDataStore = .default(), phoneLayout: Bool = false) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let relay = LostRelay()
        configuration.userContentController.add(relay, name: LostRelay.name)
        #if canImport(UIKit)
        let webView = phoneLayout ? EditorWebView(frame: .zero, configuration: configuration) : WKWebView(frame: .zero, configuration: configuration)
        #else
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        self.webView = webView
        self.phoneLayout = phoneLayout
        super.init()
        relay.browser = self
        installUserScripts()
        #if canImport(UIKit)
        (webView as? EditorWebView)?.keyRow = EditorKeyRow(
            press: { [weak self] key in self?.press(key) },
            dismiss: { [weak webView] in webView?.endEditing(true) })
        #endif
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func load(_ url: URL) {
        Self.log.info("editor page loads \(url.host() ?? "-", privacy: .public):\(url.port ?? 0)")
        webView.load(URLRequest(url: url))
    }

    func reload() { webView.reload() }

    @ObservationIgnored private let phoneLayout: Bool
    @ObservationIgnored private var viewport: String?

    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(LostRelay.script)
        guard phoneLayout else { return }
        controller.addUserScript(EditorPhoneLayout.userScript)
        if let viewport { controller.addUserScript(EditorPhoneLayout.viewportUserScript(viewport)) }
    }

    @ObservationIgnored private var fittedSize: CGSize?

    /// Lays the workbench out for a pane of this size, now and in pages loaded later.
    func fit(to size: CGSize) {
        guard phoneLayout else { return }
        fittedSize = size
        guard let content = EditorPhoneLayout.viewport(for: size, zoom: EditorPhoneLayout.zoom), content != viewport else { return }
        viewport = content
        installUserScripts()
        webView.evaluateJavaScript(EditorPhoneLayout.viewportScript(content, createsMissing: true))
    }

    var canZoom: (in: Bool, out: Bool) {
        let zoom = EditorPhoneLayout.zoom
        return (EditorPhoneLayout.zoom(from: zoom, by: 1) != nil, EditorPhoneLayout.zoom(from: zoom, by: -1) != nil)
    }

    /// +1 zooms in, -1 out, 0 back to fitting the pane.
    func zoom(by direction: Int) {
        let zoom = direction == 0 ? 1 : EditorPhoneLayout.zoom(from: EditorPhoneLayout.zoom, by: direction)
        guard let zoom else { return }
        UserDefaults.standard.set(Double(zoom), forKey: EditorPhoneLayout.zoomKey)
        if let fittedSize { fit(to: fittedSize) }
    }

    func run(_ command: EditorPhoneLayout.Command) {
        evaluate(EditorPhoneLayout.script(for: command), name: command.rawValue)
    }

    func press(_ key: EditorPhoneLayout.Key) {
        evaluate(EditorPhoneLayout.script(for: key), name: key.code)
    }

    private func evaluate(_ script: String, name: String) {
        Task { @MainActor in
            do {
                _ = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            } catch {
                Self.log.error("editor \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit loads the request into the returned view itself, keeping `window.opener`.
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.uiDelegate = self
        child.navigationDelegate = self
        #if DEBUG
        child.isInspectable = true
        #endif
        Self.log.info("editor popup \(navigationAction.request.url?.host() ?? "-", privacy: .public)")
        popup = Popup(webView: child)
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if popup?.webView === webView { popup = nil }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let decision = Self.decision(
            for: url, mainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
            clicked: navigationAction.navigationType == .linkActivated, desktopURI: desktopURI?())
        switch decision {
        case .allow: return .allow
        case .cancel: return .cancel
        case .openExternally:
            if let url { Self.openExternally(url) }
            return .cancel
        case .confirm:
            if let url { Task { @MainActor in Self.confirmOpen(url, from: webView) } }
            return .cancel
        }
    }

    /// Desktop VS Code's address for the tunnel this page shows, as the daemon gave it.
    @ObservationIgnored var desktopURI: (@MainActor () -> URL?)?

    enum NavigationDecision: Equatable {
        case allow
        case cancel
        /// Cancel, and hand the link to the app that owns its scheme.
        case openExternally
        /// Cancel, and hand the link on only once the user said so, seeing where it goes.
        case confirm
    }

    /// Web content (the workbench, extensions, whatever they load) is untrusted, so it starts
    /// another app only from a link the user clicked in the main frame, and only for
    /// `externalSchemes` (never `file:` or this app's own links). Only the exact desktop address
    /// of this tunnel opens without asking: a crafted `vscode:` link can clone a repository or
    /// connect to someone else's tunnel.
    static func decision(for url: URL?, mainFrame: Bool, clicked: Bool, desktopURI: URL?) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        guard mainFrame, clicked, externalSchemes.contains(scheme) else { return .cancel }
        return url.absoluteString == desktopURI?.absoluteString ? .openExternally : .confirm
    }

    static let externalSchemes: Set<String> = ["vscode", "vscode-insiders", "mailto", "tel"]

    static func confirmation(for url: URL) -> (title: String, message: String) {
        let title = switch url.scheme?.lowercased() {
        case "vscode": "Open in VS Code?"
        case "vscode-insiders": "Open in VS Code Insiders?"
        case "mailto": "Open in Mail?"
        default: "Open This Link?"
        }
        return (title, LinkSafety.display(url) + "\n\nThe editor page asked to open this.")
    }

    private static func confirmOpen(_ url: URL, from webView: WKWebView) {
        let text = confirmation(for: url)
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { openExternally(url) }
        #else
        let alert = UIAlertController(title: text.title, message: text.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in openExternally(url) })
        var presenter = webView.window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(alert, animated: true)
        #endif
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { isLoading = true }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isLoading = false
        onLoad?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard webView === self.webView else { return }
        isLoading = false
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard webView === self.webView else { return }
        isLoading = false
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        Self.log.error("editor web content process ended")
        onLost?("its web content process ended")
    }

    private func failed(_ error: any Error) {
        // A newer load replacing this one is not a failure.
        if (error as NSError).code == NSURLErrorCancelled { return }
        Self.log.error("editor page failed: \(String(describing: error), privacy: .public)")
        onFail?(error.localizedDescription)
    }

    static func openExternally(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

/// Notices VS Code's "Cannot reconnect" dialog, shown once the server has lost the session.
/// `browser` is weak so the content controller does not keep it alive.
@MainActor
private final class LostRelay: NSObject, WKScriptMessageHandler {
    static let name = "editorLost"
    weak var browser: TunnelBrowser?

    /// Checks dialogs only, at most once a second: the workbench mutates the page constantly.
    static let script = WKUserScript(source: """
        (() => {
          let said = false, queued = false;
          const look = () => {
            queued = false;
            if (said) return;
            for (const el of document.querySelectorAll('.monaco-dialog-box .dialog-message-text')) {
              if (/Cannot reconnect|reload the window/i.test(el.textContent || '')) {
                said = true;
                window.webkit.messageHandlers.\(name).postMessage('cannot reconnect');
                return;
              }
            }
          };
          new MutationObserver(() => {
            if (!queued) { queued = true; setTimeout(look, 1000); }
          }).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let reason = (message.body as? String) ?? "lost"
        TunnelBrowser.log.error("editor workbench: \(reason, privacy: .public)")
        browser?.onLost?("the workbench says: \(reason)")
    }
}

struct WebViewHost: View {
    let webView: WKWebView

    var body: some View { Representable(webView: webView) }

    #if canImport(UIKit)
    private struct Representable: UIViewRepresentable {
        let webView: WKWebView
        func makeUIView(context: Context) -> WKWebView { webView }
        func updateUIView(_ view: WKWebView, context: Context) {}
    }
    #else
    private struct Representable: NSViewRepresentable {
        let webView: WKWebView
        func makeNSView(context: Context) -> WKWebView { webView }
        func updateNSView(_ view: WKWebView, context: Context) {}
    }
    #endif
}

/// A window vscode.dev opened, usually a sign-in. Open in Browser is for pages that refuse to
/// work inside an app.
struct EditorPopupSheet: View {
    let popup: TunnelBrowser.Popup
    var close: () -> Void

    var body: some View {
        NavigationStack {
            WebViewHost(webView: popup.webView)
                .ignoresSafeArea(edges: .bottom)
                .accessibilityIdentifier("editor-popup-web")
                .navigationTitle(popup.webView.url?.host() ?? "Sign In")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: close)
                            .accessibilityIdentifier("editor-popup-done")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open in Browser", systemImage: "safari") {
                            if let url = popup.webView.url, HostLinks.mayOpen(url) { TunnelBrowser.openExternally(url) }
                            close()
                        }
                        .help("Continue in your browser")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 680)
        #endif
    }
}
