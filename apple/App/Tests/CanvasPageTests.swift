import TerminalCore
import WebKit
import XCTest
@testable import App
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The drawing page in its web view: Paste brings the system clipboard's image or text into the
/// drawing (the page cannot read the clipboard itself), Excalidraw's own Paste reads it through
/// the app, and Send and Copy export the drawing as the canvas shows it, in the theme, on the
/// pane's background, with a pasted screenshot as itself rather than its negative.
@MainActor
final class CanvasPageTests: XCTestCase {
    private static let navy = RGB(r: 0x20, g: 0x27, b: 0x46)
    private static let size = CGSize(width: 480, height: 400)

    private var web: CanvasWebView!
    private var loaded = false
    private var pasteboard: CanvasClipboard.Pasteboard!
    private var savedPasteboard: CanvasClipboard.Pasteboard!
    #if os(macOS)
    private var window: NSWindow!
    #else
    private var window: UIWindow!
    #endif

    override func setUp() async throws {
        savedPasteboard = CanvasClipboard.pasteboard
        #if os(macOS)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("canvas-tests-\(UUID().uuidString)"))
        #else
        pasteboard = UIPasteboard.withUniqueName()
        #endif
        CanvasClipboard.pasteboard = pasteboard
        web = CanvasWebView()
        web.onMessage = { [weak self] message in
            if message["type"] as? String == "loaded" { self?.loaded = true }
        }
        #if os(macOS)
        window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: Self.size.width, height: Self.size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        web.webView.frame = NSRect(origin: .zero, size: Self.size)
        window.contentView?.addSubview(web.webView)
        window.orderFrontRegardless()
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        let root = UIViewController()
        window.rootViewController = root
        web.webView.frame = CGRect(origin: .zero, size: Self.size)
        root.view.addSubview(web.webView)
        window.makeKeyAndVisible()
        #endif
        web.call("load", [
            "mode": "canvas", "theme": "dark", "readOnly": false, "elements": [], "files": [], "appState": [:],
        ] as [String: Any])
        try await waitFor("the editor loads") { self.loaded }
    }

    override func tearDown() async throws {
        web.tearDown()
        web.webView.removeFromSuperview()
        #if os(macOS)
        window.close()
        pasteboard.releaseGlobally()
        #else
        window.isHidden = true
        UIPasteboard.remove(withName: pasteboard.name)
        #endif
        CanvasClipboard.pasteboard = savedPasteboard
    }

    // MARK: Paste

    func testPasteBringsTheClipboardsImageIntoTheDrawing() async throws {
        put(image: Self.lightScreenshot())
        XCTAssertTrue(canPaste(), "Paste is on while the clipboard has something")
        paste()
        try await waitForPastedImage()
        let image = await element(ofType: "image")
        let width = try XCTUnwrap(image?["width"] as? Double)
        XCTAssertEqual(width, 160, accuracy: 1, "at its own size")

        try await Task.sleep(for: .seconds(1))
        let shown = try await web.webView.takeSnapshot(configuration: nil)
        #if os(macOS)
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(shown.tiffRepresentation))?.representation(using: .png, properties: [:]))
        #else
        let png = try XCTUnwrap(shown.pngData())
        #endif
        keep(png, name: "canvas-paste-dark")
        let picture = try Picture(png: png)
        let scale = Double(picture.width) / Self.size.width
        let band = 56.0
        let middle = picture.color(at: CGPoint(x: Self.size.width / 2 * scale, y: (band + (Self.size.height - band) / 2) * scale))
        XCTAssertGreaterThan(middle.r, 170, "pasted in the middle of the view, a light screenshot shows light on the dark canvas: \(middle)")
    }

    func testPasteBringsTheClipboardsTextIntoTheDrawing() async throws {
        put(text: "Login flow")
        paste()
        try await waitFor("a text element") { await self.texts().contains("Login flow") }
    }

    /// ⌘V and the Edit menu's Paste start at the window's first responder: the page (on iOS,
    /// WebKit's own view inside it).
    func testPasteFromTheFirstResponderReachesTheDrawing() async throws {
        #if os(macOS)
        window.makeFirstResponder(web.webView)
        #else
        web.webView.claimKeyboard()
        try await waitFor("the page takes the keyboard") { self.web.webView.ownsKeyboard }
        #endif
        put(text: "From the keyboard")
        #if os(macOS)
        let sent = window.firstResponder?.tryToPerform(#selector(CanvasPageView.paste(_:)), with: nil) ?? false
        #else
        let sent = UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste(_:)), to: nil, from: nil, for: nil)
        #endif
        XCTAssertTrue(sent, "the page's first responder takes Paste")
        try await waitFor("a text element") { await self.texts().contains("From the keyboard") }
    }

    func testExcalidrawsOwnPasteReadsTheClipboardThroughTheApp() async throws {
        put(image: Self.lightScreenshot())
        let types = await web.runAsync("const items = await navigator.clipboard.read(); return items.flatMap((item) => item.types).join(',')")
        XCTAssertEqual(types as? String, "image/png")
        put(text: "hello")
        let text = await web.runAsync("return await navigator.clipboard.readText()")
        XCTAssertEqual(text as? String, "hello")
    }

    // MARK: Export

    /// Send and Copy: the drawing on the pane's background, in the dark theme, and a mostly white
    /// screenshot pasted into it still mostly white (WebKit has no canvas `filter`, which
    /// Excalidraw uses to keep images as they are under its dark theme).
    func testExportIsInTheThemeOnThePanesBackground() async throws {
        put(image: Self.lightScreenshot())
        paste()
        try await waitForPastedImage()
        let found = await element(ofType: "image")
        let image = try XCTUnwrap(found)
        let x = try XCTUnwrap(image["x"] as? Double), y = try XCTUnwrap(image["y"] as? Double)
        let width = try XCTUnwrap(image["width"] as? Double), height = try XCTUnwrap(image["height"] as? Double)
        web.call("debugRect", ["x": x + width + 160, "y": y, "width": 20, "height": 20])
        try await waitFor("a rectangle beside it") { await self.types().contains("rectangle") }
        try await Task.sleep(for: .seconds(1))

        let exported = await web.export(scale: 1, bounds: nil, background: true, backgroundColor: Self.navy)
        let png = try XCTUnwrap(exported?.data)
        keep(png, name: "canvas-export-dark")
        let picture = try Picture(png: png)
        let gap = picture.color(at: CGPoint(x: width + 80, y: height / 2))
        XCTAssertEqual(gap.r, Int(Self.navy.r), accuracy: 3, "the pane's background, not transparent or white")
        XCTAssertEqual(gap.g, Int(Self.navy.g), accuracy: 3)
        XCTAssertEqual(gap.b, Int(Self.navy.b), accuracy: 3)
        let screenshot = picture.color(at: CGPoint(x: width / 2, y: height / 2))
        XCTAssertGreaterThan(screenshot.r, 170, "a light screenshot stays light, not its negative: \(screenshot)")
        XCTAssertGreaterThan(screenshot.g, 170)
        XCTAssertGreaterThan(screenshot.b, 170)
    }

    // MARK: Helpers

    private func put(image png: Data) {
        #if os(macOS)
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        #else
        pasteboard.setData(png, forPasteboardType: "public.png")
        #endif
    }

    private func put(text: String) {
        #if os(macOS)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #else
        pasteboard.string = text
        #endif
    }

    private func canPaste() -> Bool {
        #if os(macOS)
        let item = NSMenuItem(title: "Paste", action: #selector(CanvasPageView.paste(_:)), keyEquivalent: "v")
        return (web.webView as? CanvasPageView)?.validateUserInterfaceItem(item) ?? false
        #else
        return web.webView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil)
        #endif
    }

    /// The Edit menu's Paste (⌘V) as it reaches the page's view.
    private func paste() {
        #if os(macOS)
        NSApp.sendAction(#selector(CanvasPageView.paste(_:)), to: web.webView, from: nil)
        #else
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste(_:)), to: web.webView, from: nil, for: nil)
        #endif
    }

    /// An image element with its picture, once the editor has read it.
    private func waitForPastedImage() async throws {
        try await waitFor("the pasted image") {
            guard let image = await self.element(ofType: "image"), let file = image["fileId"] as? String else { return false }
            let files = await self.web.value("JSON.parse(canvas.snapshot()).files") as? [String] ?? []
            return files.contains(file)
        }
    }

    private func elements() async -> [[String: Any]] {
        (await web.value("JSON.parse(canvas.snapshot()).elements") as? [[String: Any]]) ?? []
    }

    private func types() async -> [String] {
        await elements().compactMap { $0["type"] as? String }
    }

    private func texts() async -> [String] {
        await elements().compactMap { $0["text"] as? String }
    }

    private func element(ofType type: String) async -> [String: Any]? {
        await elements().first { $0["type"] as? String == type }
    }

    private func waitFor(_ what: String, timeout: Double = 15, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting for \(what): \(await elements())")
        throw XCTSkip("gave up")
    }

    private func keep(_ png: Data, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["THEME_SHOTS_DIR"] else { return }
        #if os(macOS)
        let platform = "mac"
        #else
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(platform)-\(name).png"))
    }

    /// A light window screenshot: near-white with a grey title strip.
    private static func lightScreenshot() -> Data {
        let width = 160, height = 100
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let shade: UInt8 = y < 16 ? 214 : 246
                pixels[offset] = shade
                pixels[offset + 1] = shade
                pixels[offset + 2] = shade
                pixels[offset + 3] = 255
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private struct Picture {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        init(png: Data) throws {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            width = image.width
            height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.pixels = pixels
        }

        func color(at point: CGPoint) -> (r: Int, g: Int, b: Int, a: Int) {
            let x = min(width - 1, max(0, Int(point.x))), y = min(height - 1, max(0, Int(point.y)))
            let offset = (y * width + x) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]), Int(pixels[offset + 3]))
        }
    }
}
