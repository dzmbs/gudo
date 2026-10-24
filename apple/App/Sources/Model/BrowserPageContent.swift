import SwiftUI
import WebKit

/// What a browser pane shows and agents act on: WebKit's SwiftUI `WebPage`, or the `WKWebView`
/// of a page another page opened (`PopupPage`). The two meet here, so the browser's chrome,
/// agents' tools and the recorder treat them alike.
@MainActor
protocol BrowserPageContent: AnyObject {
    var url: URL? { get }
    var title: String { get }
    var isLoading: Bool { get }
    var estimatedProgress: Double { get }
    var hasOnlySecureContent: Bool { get }
    /// Pages behind, oldest first, and ahead, nearest first.
    var history: (back: [BrowserHistoryItem], forward: [BrowserHistoryItem]) { get }

    func open(_ request: URLRequest)
    func go(to item: BrowserHistoryItem)
    func reloadPage()
    func stopLoading()
    /// Runs `body` as an async function in the main frame.
    func run(_ body: String, arguments: [String: Any], in world: WKContentWorld) async throws -> Any?
    /// The page drawn `width` points wide: `region` of it (CSS pixels), or all of it.
    func picture(_ region: CGRect?, width: Double) async throws -> Data
}

extension BrowserPageContent {
    func run(_ body: String, in world: WKContentWorld) async throws -> Any? {
        try await run(body, arguments: [:], in: world)
    }

    func goBack() { if let item = history.back.last { go(to: item) } }
    func goForward() { if let item = history.forward.first { go(to: item) } }
}

/// A page in a pane's history, by its distance from the current one (-1: just behind).
struct BrowserHistoryItem: Identifiable, Equatable {
    let offset: Int
    let title: String?
    let url: URL

    var id: Int { offset }
}

extension WebPage: BrowserPageContent {
    var history: (back: [BrowserHistoryItem], forward: [BrowserHistoryItem]) {
        let list = backForwardList
        let back = list.backList.enumerated().map { BrowserHistoryItem(offset: $0.offset - list.backList.count, title: $0.element.title, url: $0.element.url) }
        let forward = list.forwardList.enumerated().map { BrowserHistoryItem(offset: $0.offset + 1, title: $0.element.title, url: $0.element.url) }
        return (back, forward)
    }

    func open(_ request: URLRequest) { _ = load(request) }

    func go(to item: BrowserHistoryItem) {
        let list = backForwardList
        let target = item.offset < 0
            ? list.backList.indices.contains(list.backList.count + item.offset) ? list.backList[list.backList.count + item.offset] : nil
            : list.forwardList.indices.contains(item.offset - 1) ? list.forwardList[item.offset - 1] : nil
        if let target { _ = load(target) }
    }

    func reloadPage() { _ = reload() }

    func run(_ body: String, arguments: [String: Any], in world: WKContentWorld) async throws -> Any? {
        try await callJavaScript(body, arguments: arguments, contentWorld: world)
    }

    func picture(_ region: CGRect?, width: Double) async throws -> Data {
        try await exported(as: .image(region: region.map { .rect($0) } ?? .contents, snapshotWidth: width))
    }
}

/// A page another page opened (`window.open`, a `target=_blank` link) in the web view WebKit
/// configured for it, so `window.opener`, `postMessage` back to it and `window.close()` work
/// as in a browser. `WebPage` can't adopt a given configuration, hence a plain `WKWebView`.
@MainActor
@Observable
final class PopupPage: NSObject, BrowserPageContent {
    @ObservationIgnored let webView: WKWebView
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var hasOnlySecureContent = false
    /// Bumped as the history changes, so views reading `history` refresh.
    private var historyVersion = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(configuration: WKWebViewConfiguration) {
        // A size until its leaf lays it out: scripts measure the page as soon as it loads.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        observe(\.url) { $0.url = $1.url }
        observe(\.title) { $0.title = $1.title ?? "" }
        observe(\.isLoading) { $0.isLoading = $1.isLoading }
        observe(\.estimatedProgress) { $0.estimatedProgress = $1.estimatedProgress }
        observe(\.hasOnlySecureContent) { $0.hasOnlySecureContent = $1.hasOnlySecureContent }
        observe(\.canGoBack) { page, _ in page.historyVersion += 1 }
        observe(\.canGoForward) { page, _ in page.historyVersion += 1 }
    }

    private func observe<Value>(_ key: KeyPath<WKWebView, Value>, _ apply: @escaping @MainActor (PopupPage, WKWebView) -> Void) {
        observations.append(webView.observe(key, options: [.initial, .new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self, web)
            }
        })
    }

    var history: (back: [BrowserHistoryItem], forward: [BrowserHistoryItem]) {
        _ = historyVersion
        let list = webView.backForwardList
        let back = list.backList.enumerated().map { BrowserHistoryItem(offset: $0.offset - list.backList.count, title: $0.element.title, url: $0.element.url) }
        let forward = list.forwardList.enumerated().map { BrowserHistoryItem(offset: $0.offset + 1, title: $0.element.title, url: $0.element.url) }
        return (back, forward)
    }

    func open(_ request: URLRequest) { webView.load(request) }

    func go(to item: BrowserHistoryItem) {
        if let target = webView.backForwardList.item(at: item.offset) { webView.go(to: target) }
    }

    func reloadPage() { webView.reload() }

    func stopLoading() { webView.stopLoading() }

    func run(_ body: String, arguments: [String: Any], in world: WKContentWorld) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
    }

    func picture(_ region: CGRect?, width: Double) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        // Without a region, the whole document.
        if let region {
            configuration.rect = region
        } else if let size = try await run("return [document.documentElement.scrollWidth, document.documentElement.scrollHeight]", in: .defaultClient) as? [Double], size.count == 2 {
            configuration.rect = CGRect(x: 0, y: 0, width: size[0], height: size[1])
        }
        configuration.snapshotWidth = NSNumber(value: width)
        configuration.afterScreenUpdates = false
        let image = try await webView.takeSnapshot(configuration: configuration)
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw BrowserCallError("The page could not be drawn.") }
        return data
        #else
        guard let data = image.pngData() else { throw BrowserCallError("The page could not be drawn.") }
        return data
        #endif
    }
}

/// Shows a popup's web view in its leaf, with the page's appearance from the environment.
struct PopupWebView {
    let page: PopupPage
    let colorScheme: ColorScheme
}

#if os(macOS)
extension PopupWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { page.webView }

    func updateNSView(_ view: WKWebView, context: Context) {
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
}
#else
extension PopupWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { page.webView }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    }
}
#endif
