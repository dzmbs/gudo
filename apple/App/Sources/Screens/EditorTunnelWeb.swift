import Observation
import os
import SwiftUI
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

    init(dataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let relay = LostRelay()
        configuration.userContentController.add(relay, name: LostRelay.name)
        configuration.userContentController.addUserScript(LostRelay.script)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        relay.browser = self
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
        switch Self.decision(for: url, mainFrame: navigationAction.targetFrame?.isMainFrame ?? true) {
        case .allow: return .allow
        case .cancel: return .cancel
        case .openExternally:
            if let url { Self.openExternally(url) }
            return .cancel
        }
    }

    enum NavigationDecision: Equatable {
        case allow
        case cancel
        /// Cancel, and hand the link to the app that owns its scheme.
        case openExternally
    }

    /// Extensions' web views are untrusted content, so only the main frame may hand links to
    /// other apps, and only for `externalSchemes` (never `file:` or this app's own links).
    static func decision(for url: URL?, mainFrame: Bool) -> NavigationDecision {
        guard let scheme = url?.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        return mainFrame && externalSchemes.contains(scheme) ? .openExternally : .cancel
    }

    static let externalSchemes: Set<String> = ["vscode", "vscode-insiders", "mailto", "tel"]

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
                            if let url = popup.webView.url { TunnelBrowser.openExternally(url) }
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
