import WebKit

/// New windows and closing for a page. `WebPage` has no API for either, so its web view's UI
/// delegate is wrapped: `window.open` becomes a new browser leaf (`BrowserPane.onPopup`), and
/// everything else goes on to `WebPage`'s own delegate (dialogs, file pickers).
///
/// A page opened that way loads on its own, without `window.opener`, so WebKit would refuse
/// its `window.close()`; `closeScript` lets it close its leaf instead.
@MainActor
final class BrowserWindows: NSObject, WKUIDelegate, WKScriptMessageHandler {
    /// The message handler a popup's `window.close()` posts to.
    static let closeHandler = "unCloseWindow"
    static let closeScript = WKUserScript(
        source: "window.close = () => window.webkit.messageHandlers.\(closeHandler).postMessage(0);",
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private weak var webView: WKWebView?
    /// `WebPage`'s delegate (it keeps it alive). Read by the forwarding below, which WebKit
    /// calls on the main thread.
    nonisolated(unsafe) private weak var inner: (any WKUIDelegate)?
    var onOpen: ((URL) -> Void)?
    var onClose: (() -> Void)?

    /// Puts itself in front of `webView`'s delegate, once.
    func adopt(_ webView: WKWebView) {
        guard self.webView !== webView, webView.uiDelegate !== self else { return }
        self.webView = webView
        inner = webView.uiDelegate
        webView.uiDelegate = self
    }

    /// Lets scripts open windows without a user gesture (while an agent acts).
    func allowPopups(_ on: Bool) {
        webView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = on
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme) { onOpen?(url) }
        return nil
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
