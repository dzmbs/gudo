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
      #knob { left: 150px; top: 140px; width: 40px; height: 40px; background: #333; }
      #dst { left: 300px; top: 140px; width: 120px; height: 120px; background: #0cf; }
      #field { left: 20px; top: 300px; width: 200px; height: 30px; }
    </style>
    <div id="hover">Hover</div><div id="menu">Menu</div>
    <button id="go">Go</button>
    <div id="src" draggable="true">Drag</div><div id="knob"></div><div id="dst">Drop</div>
    <input id="field">
    <script>
      window.log = [];
      const note = e => log.push(e.type + ":" + e.target.id + ":" + e.isTrusted + (e.buttons ? ":pressed" : ""));
      for (const t of ["mouseover", "click", "dblclick", "mousedown", "mouseup", "dragstart", "drop", "keydown", "input"])
        addEventListener(t, note, true);
      addEventListener("mousemove", e => { if (log.at(-1) !== "mousemove:" + e.target.id + ":" + e.isTrusted) note(e); }, true);
      dst.addEventListener("dragover", e => e.preventDefault());
      src.addEventListener("dragstart", e => e.dataTransfer.setData("text/plain", "x"));
    </script>
    """

    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func page(agent: Bool = false) async throws -> WebPage {
        var configuration = WebPage.Configuration()
        if agent { BrowserAgentScript.install(in: configuration.userContentController) }
        let page = WebPage(configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WebView(page).frame(width: 800, height: 600))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        for try await event in page.load(html: html, baseURL: URL(string: "https://fixture.test/")!) where event == .finished { break }
        try await Task.sleep(for: .milliseconds(300))
        return page
    }

    private func log(_ page: WebPage) async throws -> [String] {
        try await page.callJavaScript("return log.splice(0)") as? [String] ?? []
    }

    private func act(_ page: WebPage, _ args: [String: Any]) async throws -> [String: Any] {
        try await page.callJavaScript("return window.__un.act(args)", arguments: ["args": args], contentWorld: BrowserAgentScript.world) as? [String: Any] ?? [:]
    }

    /// The agent's actions on the Mac: the page script checks the target and lists the events,
    /// the app sends them, and the effect is read as before. HTML drag sources stay with the
    /// script's DataTransfer drag.
    func testAgentActionsGoThroughNativeInput() async throws {
        let page = try await page(agent: true)
        let found = await BrowserNativeInput.for(page)
        let input = try XCTUnwrap(found)
        let snapshot = try await page.callJavaScript("return window.__un.snapshot(args)", arguments: ["args": ["full": true]], contentWorld: BrowserAgentScript.world) as? String ?? ""
        let line = try XCTUnwrap(snapshot.split(separator: "\n").first { $0.contains("button \"Go\"") }, snapshot)
        let ref = String(try XCTUnwrap(line.firstMatch(of: /\[(ref_\d+)\]/)).output.1)

        let done = try await act(page, ["kind": "click", "phase": "do", "native": true, "id": "c1", "target": ["type": "ref", "ref": ref]])
        let ops = try XCTUnwrap(done["native"] as? [[String: Any]], "\(done)")
        XCTAssertEqual(ops.first?["op"] as? String, "click")
        let untouched = try await log(page)
        XCTAssertFalse(untouched.contains { $0.hasPrefix("click:") }, "the script itself sent nothing: \(untouched)")
        await input.perform(ops)
        let clicked = try await log(page)
        XCTAssertTrue(clicked.contains("click:go:true"), "\(clicked)")

        let focus = try await act(page, ["kind": "click", "phase": "do", "native": true, "id": "f1", "target": ["type": "coordinate", "x": 120, "y": 315]])
        await input.perform(focus["native"] as? [[String: Any]] ?? [])
        let typed = try await act(page, ["kind": "type", "phase": "do", "native": true, "id": "t1", "text": "Ada", "submit": false])
        await input.perform(try XCTUnwrap(typed["native"] as? [[String: Any]], "\(typed)"))
        let effect = try await page.callJavaScript("return window.__un.effect('t1')", contentWorld: BrowserAgentScript.world) as? [String: Any]
        XCTAssertTrue((effect?["changes"] as? [String])?.contains("value changed") == true, "\(String(describing: effect))")

        // A pointer drag is the app's; an HTML drag source is the script's.
        let knob = try await act(page, ["kind": "drag", "phase": "do", "native": true, "id": "d1",
                                        "target": ["type": "coordinate", "x": 170, "y": 160], "to": ["type": "coordinate", "x": 360, "y": 200]])
        XCTAssertEqual((knob["native"] as? [[String: Any]])?.first?["op"] as? String, "drag")
        _ = try await log(page)
        let html = try await act(page, ["kind": "drag", "phase": "do", "native": true, "id": "d2",
                                        "target": ["type": "coordinate", "x": 60, "y": 180], "to": ["type": "coordinate", "x": 360, "y": 200]])
        XCTAssertNil(html["native"])
        let dropped = try await log(page)
        XCTAssertTrue(dropped.contains { $0.hasPrefix("dragstart:src:") } && dropped.contains { $0.hasPrefix("drop:dst:") }, "\(dropped)")
    }

    func testPointerKeysAndDragArriveAsTheUsersOwn() async throws {
        let page = try await page()
        let found = await BrowserNativeInput.for(page)
        let input = try XCTUnwrap(found, "the page's view is found")

        await input.move(to: CGPoint(x: 70, y: 35))
        await input.move(to: CGPoint(x: 80, y: 40))
        try await Task.sleep(for: .milliseconds(300))
        // WebKit takes moves without a button only in the key window, which a test run in the
        // background never has; in the app the page's window is key while the user watches.
        if window?.isKeyWindow == true {
            let hovered = try await page.callJavaScript("return [getComputedStyle(hover).backgroundColor, getComputedStyle(menu).display]") as? [String]
            XCTAssertEqual(hovered, ["rgb(0, 128, 0)", "block"], ":hover holds and opens the menu")
            let over = try await log(page)
            XCTAssertTrue(over.contains("mouseover:hover:true"), "\(over)")
        } else {
            _ = try await log(page)
        }

        await input.click(at: CGPoint(x: 240, y: 40))
        let clicks = try await log(page)
        XCTAssertTrue(clicks.contains("click:go:true"), "\(clicks)")
        await input.click(at: CGPoint(x: 240, y: 40), count: 2)
        let double = try await log(page)
        XCTAssertTrue(double.contains("dblclick:go:true"), "\(double)")

        // A pointer drag; an HTML drag source is left to the page script.
        let dragged = await input.drag(from: CGPoint(x: 170, y: 160), to: CGPoint(x: 360, y: 200))
        XCTAssertTrue(dragged)
        let drag = try await log(page)
        XCTAssertTrue(drag.contains("mousedown:knob:true"), "\(drag)")
        // Moves with the button down reach what the pointer passes over.
        XCTAssertTrue(drag.contains("mousemove:dst:true"), "\(drag)")
        XCTAssertTrue(drag.contains { $0.hasPrefix("mouseup:") && $0.contains(":true") }, "\(drag)")
        let refused = await input.drag(from: CGPoint(x: 60, y: 180), to: CGPoint(x: 360, y: 200))
        XCTAssertFalse(refused)

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
