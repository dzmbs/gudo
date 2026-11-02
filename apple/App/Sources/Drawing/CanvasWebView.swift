import Foundation
import os
import WebKit

/// The bundled, offline Excalidraw (built by scripts/build-excalidraw.sh) in a transparent
/// `WKWebView`. Swift calls `window.canvas.<fn>(json)`; the page posts to
/// `window.webkit.messageHandlers.canvas`.
@MainActor
final class CanvasWebView: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// `<brand>-canvas://bundle/index.html`: pages load from the app bundle, never the network.
    static let scheme: String = {
        let brand = Brand.name.lowercased().filter { $0.isLetter || $0.isNumber }
        return (brand.isEmpty ? "app" : brand) + "-canvas"
    }()

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "drawing")

    let webView: WKWebView
    /// Messages from the page: a `type` plus its fields.
    var onMessage: (([String: Any]) -> Void)?
    private(set) var isReady = false
    private var queued: [String] = []
    private var exports: [String: CheckedContinuation<ExportReply, Never>] = [:]
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: Self.scheme)
        configuration.websiteDataStore = .nonPersistent()
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = false
        #endif
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(WeakMessageHandler(self), name: "canvas")
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        #else
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        #endif
        webView.allowsLinkPreview = false
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://bundle/index.html")!))
    }

    /// Calls `window.canvas.<function>(argument)`; queued until the page is ready.
    func call(_ function: String, _ argument: Any = [String: Any]()) {
        guard let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        let script = "window.canvas && window.canvas.\(function)(\(json)); undefined;"
        if isReady {
            webView.evaluateJavaScript(script) { _, error in
                if let error { Self.log.error("canvas.\(function, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
        } else {
            queued.append(script)
        }
    }

    func value(_ expression: String) async -> Any? {
        await waitUntilReady()
        guard let result = try? await webView.evaluateJavaScript("JSON.stringify(\(expression))") as? String,
              let data = result.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Runs an async function body in the page (`await` allowed) and returns its result.
    @discardableResult
    func runAsync(_ body: String) async -> Any? {
        await waitUntilReady()
        do {
            return try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            Self.log.error("canvas script: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func waitUntilReady() async {
        guard !isReady else { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// `bounds` in scene px fixes the exported area; `scale` is image pixels per scene px.
    func export(format: String = "png", scale: CGFloat, bounds: CGRect?, background: Bool = false) async -> (data: Data, count: Int)? {
        await waitUntilReady()
        let id = UUID().uuidString
        var argument: [String: Any] = ["requestId": id, "format": format, "scale": Double(scale), "exportPadding": 0, "background": background]
        if let bounds {
            argument["bounds"] = ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height]
        }
        let reply = await withCheckedContinuation { continuation in
            exports[id] = continuation
            call("exportImage", argument)
        }
        guard let base64 = reply.data, let data = Data(base64Encoded: base64) else {
            Self.log.error("export failed: \(reply.error ?? "no data", privacy: .public)")
            return nil
        }
        return (data, reply.count)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.isOwnPage(message.frameInfo), let body = message.body as? [String: Any], let type = body["type"] as? String
        else { return }
        switch type {
        case "ready":
            isReady = true
            for script in queued { webView.evaluateJavaScript(script) }
            queued = []
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        case "export":
            if let id = body["requestId"] as? String, let continuation = exports.removeValue(forKey: id) {
                continuation.resume(returning: ExportReply(
                    data: body["data"] as? String, count: body["count"] as? Int ?? 0, error: body["error"] as? String))
            }
        default:
            break
        }
        onMessage?(body)
    }

    /// Only the bundled page speaks for the drawing: frames inside it (a scene's embeds) can
    /// post to the handler too.
    static func isOwnPage(_ frame: WKFrameInfo) -> Bool {
        frame.isMainFrame && frame.securityOrigin.protocol == scheme
    }

    /// The page itself never leaves the bundle, not even for a `data:` or `blob:` URL; only
    /// frames inside it (a scene's embeds) load from elsewhere.
    static func policy(for url: URL?, mainFrame: Bool) -> WKNavigationActionPolicy {
        let scheme = url?.scheme?.lowercased() ?? ""
        if scheme == Self.scheme { return .allow }
        if !mainFrame, ["about", "http", "https", "blob", "data"].contains(scheme) { return .allow }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        let policy = Self.policy(for: action.request.url, mainFrame: mainFrame)
        if policy == .cancel, mainFrame, action.navigationType == .linkActivated, let url = action.request.url,
           HostLinks.mayOpen(url)
        {
            TunnelBrowser.openExternally(url)
        }
        return policy
    }

    func tearDown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "canvas")
        for continuation in exports.values { continuation.resume(returning: ExportReply(data: nil, count: 0, error: "closed")) }
        exports = [:]
        readyWaiters.forEach { $0.resume() }
        readyWaiters = []
    }
}

struct ExportReply: Sendable {
    var data: String?
    var count: Int
    var error: String?
}

/// `WKUserContentController` retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Serves `<scheme>://bundle/<path>` from the app's `Excalidraw` resource folder.
private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let root = Bundle.main.resourceURL?.appendingPathComponent("Excalidraw", isDirectory: true)

    private static let types: [String: String] = [
        "html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2",
        "json": "application/json", "png": "image/png", "svg": "image/svg+xml", "txt": "text/plain",
    ]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let root = Self.root else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.split(separator: "/").filter { $0 != ".." }.joined(separator: "/")
        let file = root.appendingPathComponent(path.isEmpty ? "index.html" : path)
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            CanvasWebView.log.error("canvas bundle: missing \(path, privacy: .public)")
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish()
            return
        }
        let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": type, "Content-Length": "\(data.count)", "Access-Control-Allow-Origin": "*"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
