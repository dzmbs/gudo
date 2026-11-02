import WebKit
#if os(macOS)
import AppKit
#endif

/// New windows and closing for a page. `WebPage` has no API for either, so its web view's UI
/// delegate is wrapped: `window.open` and `target=_blank` become a new browser leaf holding the
/// web view WebKit configured for it (`BrowserPane.makePopup`, so `window.opener` works), and
/// everything else goes on to the inner delegate (`WebPage`'s, or a popup's `PopupDelegate`).
///
/// A page opened by URL alone (no `window.opener`), WebKit would not let `window.close()`;
/// `closeScript` lets it close its leaf instead.
@MainActor
final class BrowserWindows: NSObject, WKUIDelegate, WKScriptMessageHandler {
    /// The message handler a popup's `window.close()` posts to.
    static let closeHandler = "gudoCloseWindow"
    static let closeScript = WKUserScript(
        source: "window.close = () => window.webkit.messageHandlers.\(closeHandler).postMessage(0);",
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    private weak var webView: WKWebView?
    /// The wrapped delegate (`WebPage` keeps its own alive). Read by the forwarding below,
    /// which WebKit calls on the main thread.
    nonisolated(unsafe) private weak var inner: (any WKUIDelegate)?
    /// The web view for a new window, made with the given configuration; nil opens none.
    var onCreate: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?
    var onClose: (() -> Void)?

    /// Whether new windows come here (else WebKit's own delegate would drop them).
    var isAdopted: Bool { webView != nil }

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

/// A popup's navigation and dialogs, as `BrowserPane`'s decider and dialog presenter do them
/// for a `WebPage`.
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
    /// The agent's upload while it acts; else the user picks, as Safari asks.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        if let pane, pane.agentActing { return await pane.chooseFiles(multiple: parameters.allowsMultipleSelection) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = webView.window else { return panel.runModal() == .OK ? panel.urls : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }
    #endif
}
