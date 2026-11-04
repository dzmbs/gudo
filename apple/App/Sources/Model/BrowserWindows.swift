import WebKit
#if os(macOS)
import AppKit
#endif

/// New windows and closing for a page. `WebPage` has no API for either, so its web view's UI
/// delegate is wrapped and everything else is forwarded to the inner delegate.
///
/// WebKit won't let a page opened by URL alone `window.close()`; `closeScript` closes its leaf instead.
@MainActor
final class BrowserWindows: NSObject, WKUIDelegate, WKScriptMessageHandler {
    /// The message handler a popup's `window.close()` posts to.
    static let closeHandler = "gudoCloseWindow"
    static let closeScript = WKUserScript(
        source: "window.close = () => window.webkit.messageHandlers.\(closeHandler).postMessage(0);",
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private weak var webView: WKWebView?
    /// `WebPage` keeps its own alive. WebKit calls the forwarding below on the main thread.
    nonisolated(unsafe) private weak var inner: (any WKUIDelegate)?
    /// Nil opens no window.
    var onCreate: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?
    var onClose: (() -> Void)?

    /// Otherwise WebKit's own delegate drops new windows.
    var isAdopted: Bool { webView != nil }

    func adopt(_ webView: WKWebView) {
        guard self.webView !== webView, webView.uiDelegate !== self else { return }
        self.webView = webView
        inner = webView.uiDelegate
        webView.uiDelegate = self
    }

    func allowPopups(_ allowed: Bool) {
        webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allowed
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        onCreate?(configuration, action)
    }

    func webViewDidClose(_ webView: WKWebView) { onClose?() }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        onClose?()
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || inner?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        inner?.responds(to: selector) == true ? inner : nil
    }
}

/// A popup's navigation and dialogs, matching what `BrowserPane` does for a `WebPage`.
@MainActor
final class PopupDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var pane: BrowserPane?

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let pane else { return (.allow, preferences) }
        let policy = await pane.decide(
            action.request, newWindow: action.targetFrame == nil, mainFrame: action.targetFrame?.isMainFrame ?? true,
            type: action.navigationType, download: action.shouldPerformDownload)
        return (policy, preferences)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await pane?.present(.alert, message)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await pane?.present(.confirm, message).0 == true
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        guard let (accept, text) = await pane?.present(.prompt, prompt, defaultText: defaultText), accept else { return nil }
        return text ?? defaultText ?? ""
    }

    #if os(macOS)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        if let pane, pane.agentActing { return await pane.chooseFiles(multiple: parameters.allowsMultipleSelection, origin: frame.securityOrigin) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }
    #endif
}
