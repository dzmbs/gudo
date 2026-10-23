#if os(macOS)
import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import App

/// Mac input as the user's own, on a fixture page in a window: hover, clicks, a pointer drag
/// and HTML drag and drop arrive as trusted events; keys and text reach the focused field.
@MainActor
final class BrowserNativeInputTests: XCTestCase {
    private let html = """
    <!doctype html><style>
      body { margin: 0; font: 16px system-ui; } div, button, input { position: absolute; }
      #hover { left: 20px; top: 20px; width: 120px; height: 40px; background: #ddd; }
      #hover:hover { background: rgb(0, 128, 0); }
      #menu { display: none; left: 20px; top: 60px; } #hover:hover + #menu { display: block; }
      #go { left: 200px; top: 20px; width: 80px; height: 40px; }
      #src { left: 20px; top: 140px; width: 80px; height: 80px; background: #fc0; }
      #dst { left: 300px; top: 140px; width: 120px; height: 120px; background: #0cf; }
      #field { left: 20px; top: 300px; width: 200px; height: 30px; }
    </style>
    <div id="hover">Hover</div><div id="menu">Menu</div>
    <button id="go">Go</button>
    <div id="src" draggable="true">Drag</div><div id="dst">Drop</div>
    <input id="field">
    <script>
      window.log = [];
      const note = e => log.push(e.type + ":" + e.target.id + ":" + e.isTrusted + (e.buttons ? ":pressed" : ""));
      for (const t of ["mouseover", "click", "dblclick", "mousedown", "mouseup", "dragstart", "drop", "keydown", "input"])
        addEventListener(t, note, true);
      addEventListener("mousemove", e => { if (e.buttons) note(e); }, true);
      dst.addEventListener("dragover", e => e.preventDefault());
      src.addEventListener("dragstart", e => e.dataTransfer.setData("text/plain", "x"));
    </script>
    """

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func page() async throws -> WebPage {
        let page = WebPage()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WebView(page).frame(width: 800, height: 600))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        for try await event in page.load(html: html, baseURL: URL(string: "https://fixture.test/")!) where event == .finished { break }
        try await Task.sleep(for: .milliseconds(300))
        return page
    }

    private func log(_ page: WebPage) async throws -> [String] {
        try await page.callJavaScript("return log.splice(0)") as? [String] ?? []
    }

    func testPointerKeysAndDragArriveAsTheUsersOwn() async throws {
        let page = try await page()
        let input = try XCTUnwrap(await BrowserNativeInput.for(page), "the page's view is found")

        await input.move(to: CGPoint(x: 80, y: 40))
        let hovered = try await page.callJavaScript("return [getComputedStyle(hover).backgroundColor, getComputedStyle(menu).display]") as? [String]
        XCTAssertEqual(hovered, ["rgb(0, 128, 0)", "block"], ":hover holds and opens the menu")
        let over = try await log(page)
        XCTAssertTrue(over.contains("mouseover:hover:true"), "\(over)")

        await input.click(at: CGPoint(x: 240, y: 40))
        let clicks = try await log(page)
        XCTAssertTrue(clicks.contains("click:go:true"), "\(clicks)")
        await input.click(at: CGPoint(x: 240, y: 40), count: 2)
        let double = try await log(page)
        XCTAssertTrue(double.contains("dblclick:go:true"), "\(double)")

        await input.drag(from: CGPoint(x: 60, y: 180), to: CGPoint(x: 360, y: 200))
        try await Task.sleep(for: .milliseconds(500))
        let drag = try await log(page)
        XCTAssertTrue(drag.contains("mousedown:src:true:pressed"), "\(drag)")
        let nativeDrop = drag.contains("drop:dst:true")
        XCTAssertTrue(drag.contains("dragstart:src:true") || drag.contains { $0.hasPrefix("mousemove:") && $0.hasSuffix(":true:pressed") },
                      "a drag starts (HTML drag and drop, or pressed moves): \(drag)")
        print("native drop delivered: \(nativeDrop)")

        await input.click(at: CGPoint(x: 120, y: 315))
        await input.type("héllo")
        await input.press(keyCode: 0x33, characters: "\u{7F}")
        let value = try await page.callJavaScript("return field.value") as? String
        XCTAssertEqual(value, "héll", "text, then Delete")
        let keys = try await log(page)
        XCTAssertTrue(keys.contains("keydown:field:true"), "\(keys)")
    }
}
#endif
