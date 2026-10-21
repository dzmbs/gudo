import Observation
import os
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// vscode.dev through a VS Code Remote Tunnel, top-level in a `WKWebView` (vscode.dev refuses
/// framing). Unlike the default editor it opens popups: GitHub and Microsoft sign-in (Settings
/// Sync, Copilot) and "open in new window" come up as a sheet with their own web view that keeps
/// the opener link, and close themselves when the page calls `window.close()`. Links to other
/// apps (`vscode:`, `mailto:`) leave the app.
@MainActor
@Observable
final class TunnelBrowser: NSObject, WKUIDelegate, WKNavigationDelegate {
    @ObservationIgnored let webView: WKWebView
    /// A window the page opened, shown as a sheet.
    var popup: Popup?
    private(set) var isLoading = false
    /// The main page finished loading.
    @ObservationIgnored var onLoad: (() -> Void)?
    /// The main page could not be loaded (the error, in words).
    @ObservationIgnored var onFail: ((String) -> Void)?

    struct Popup: Identifiable {
        let id = UUID()
        let webView: WKWebView
    }

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "editor")

    override init() {
        let configuration = WKWebViewConfiguration()
        // The workbench keeps its state (open editors, sign-ins) like a desktop window.
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
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
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data"].contains(scheme) { return .allow }
        // vscode:, mailto:, tel: … belong to other apps.
        Self.openExternally(url)
        return .cancel
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

/// A `WKWebView` in SwiftUI.
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

/// A window vscode.dev opened (a sign-in, usually): its own web view, Done to close it, and
/// Open in Browser for pages that refuse to work in an app.
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
