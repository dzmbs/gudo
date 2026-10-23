import PaneLayout
import WebKit
import XCTest
@testable import App

/// The recorder on fixture pages in a real `WebPage`: rrweb, in its own content world, sees
/// the page's DOM changes and input, frames from another origin arrive through the app, and
/// the page sees none of it.
@MainActor
final class BrowserRecorderTests: XCTestCase {
    private var root: URL!
    private var saved: ReplayStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "recorder-tests-\(UUID().uuidString)")
        saved = BrowserRecorder.shared.store
        BrowserRecorder.shared.store = ReplayStore(root: root)
        UserDefaults.standard.removeObject(forKey: ReplayStore.enabledKey)
    }

    override func tearDown() async throws {
        BrowserRecorder.shared.store = saved
        try? FileManager.default.removeItem(at: root)
    }

    /// Serves `fixture-a://a/…` and `fixture-b://b/…` (two origins) from `pages`.
    private struct Fixture: URLSchemeHandler {
        let pages: [String: String]

        func reply(for request: URLRequest) -> AsyncThrowingStream<URLSchemeTaskResult, any Error> {
            AsyncThrowingStream { continuation in
                let url = request.url!
                let body = Data((pages[url.path] ?? "").utf8)
                continuation.yield(.response(URLResponse(url: url, mimeType: "text/html", expectedContentLength: body.count, textEncodingName: "utf-8")))
                continuation.yield(.data(body))
                continuation.finish()
            }
        }
    }

    private let pages = [
        "/index.html": """
        <!doctype html><title>Recorded</title>
        <script>addEventListener("message", () => { window.heard = (window.heard || 0) + 1; });</script>
        <h1>Shop</h1><input id="name" placeholder="Name"><input id="pw" type="password">
        <iframe src="fixture-b://b/frame.html" width="300" height="100"></iframe>
        """,
        "/frame.html": "<!doctype html><p id=\"t\">Card frame</p>",
    ]

    private func page(_ id: UUID) -> WebPage {
        var configuration = WebPage.Configuration()
        BrowserRecorder.install(in: configuration.userContentController, page: id)
        let fixture = Fixture(pages: pages)
        configuration.urlSchemeHandlers[URLScheme("fixture-a")!] = fixture
        configuration.urlSchemeHandlers[URLScheme("fixture-b")!] = fixture
        let page = WebPage(configuration: configuration)
        BrowserRecorder.shared.attach(page, id: id)
        return page
    }

    private func entry(_ tool: String, page: UUID, url: URL?) -> BrowserActionEntry {
        BrowserActionEntry(
            tool: tool, args: BrowserActionEntry.json(["url": url?.absoluteString ?? ""]), urlBefore: nil, urlAfter: url,
            time: .now, verdict: "done", page: page, pane: HostPane(hostId: "h1", pane: PaneId(3)))
    }

    private func load(_ page: WebPage, _ url: URL) async throws {
        for try await event in page.load(URLRequest(url: url)) where event == .finished { break }
    }

    /// Events on disk once the page went quiet, decoded.
    private func events(_ page: UUID, until done: ([[String: Any]]) -> Bool) async throws -> [[String: Any]] {
        let store = BrowserRecorder.shared.store
        for _ in 0..<40 {
            await BrowserRecorder.shared.flush(page)
            try await Task.sleep(for: .milliseconds(250))
            guard let session = store.sessions.first else { continue }
            let decoded = store.eventLines(session.id).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            if done(decoded) { return decoded }
        }
        let session = try XCTUnwrap(store.sessions.first)
        return store.eventLines(session.id).compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func text(_ event: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: event)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func testRecordsThePageItsInputAndAFrameFromAnotherOrigin() async throws {
        let id = UUID()
        let page = page(id)
        let url = URL(string: "fixture-a://a/index.html")!
        // The session starts with the agent's first action; the next page records from its start.
        BrowserRecorder.shared.record(entry("browser_navigate", page: id, url: nil))
        XCTAssertTrue(BrowserRecorder.shared.isRecording(id))
        try await load(page, url)
        try await Task.sleep(for: .milliseconds(500))

        // The page changes itself and the agent types.
        _ = try await page.callJavaScript("""
            const p = document.createElement("p"); p.textContent = "Added later"; document.body.append(p);
            const name = document.getElementById("name"); name.value = "Ada"; name.dispatchEvent(new Event("input", { bubbles: true }));
            const pw = document.getElementById("pw"); pw.value = "hunter2"; pw.dispatchEvent(new Event("input", { bubbles: true }));
            """)
        BrowserRecorder.shared.record(entry("browser_type", page: id, url: url))

        let events = try await events(id) { events in
            events.contains { text($0).contains("Card frame") } && events.contains { text($0).contains("Added later") }
        }
        let types = Set(events.compactMap { $0["type"] as? Int })
        XCTAssertTrue(types.contains(2), "a full snapshot: \(types)")
        XCTAssertTrue(events.contains { text($0).contains("Shop") }, "the page's own DOM")
        XCTAssertTrue(events.contains { text($0).contains("Added later") }, "a DOM change the page made")
        let inputs = events.filter { ($0["type"] as? Int) == 3 && (($0["data"] as? [String: Any])?["source"] as? Int) == 5 }
        XCTAssertTrue(inputs.contains { text($0).contains("Ada") }, "typed text: \(inputs.map(text))")
        XCTAssertFalse(events.contains { text($0).contains("hunter2") }, "passwords are masked")
        XCTAssertTrue(events.contains { text($0).contains("Card frame") }, "the other origin's frame, through the app")

        // Nothing of the recorder reaches the page.
        let seen = try await page.callJavaScript("""
            return [typeof window.__unReplay, typeof window.__unRRWeb, !!(window.webkit && window.webkit.messageHandlers
              && window.webkit.messageHandlers.unReplay), window.heard || 0, EventTarget.prototype.addEventListener.toString().includes("native code")]
            """) as? [Any]
        XCTAssertEqual(seen?[0] as? String, "undefined")
        XCTAssertEqual(seen?[1] as? String, "undefined")
        XCTAssertEqual(seen?[2] as? Bool, false, "no message handler in the page's world")
        XCTAssertEqual(seen?[3] as? Int, 0, "the frame's events never pass through the page")
        XCTAssertEqual(seen?[4] as? Bool, true)

        let session = try XCTUnwrap(BrowserRecorder.shared.store.sessions.first)
        XCTAssertEqual(session.actions.map(\.tool), ["browser_navigate", "browser_type"])

        // It plays back in rrweb-player, offline.
        let player = await ReplayPlayer(offline: true)
        let lines = BrowserRecorder.shared.store.eventLines(session.id)
        await player.load(events: "[" + lines.joined(separator: ",") + "]", size: CGSize(width: 640, height: 400))
        XCTAssertTrue(player.isReady)
        XCTAssertFalse(player.isEmpty)
        XCTAssertGreaterThan(player.duration, 0)
        XCTAssertGreaterThan(player.offset(of: session.actions[1]), 0)
        // The page as recorded, rebuilt in rrweb's frame (playing on needs a page on screen).
        let replayed = try await player.page.callJavaScript(
            "const f = document.querySelector('iframe'); return f && f.contentDocument ? f.contentDocument.body.textContent : ''") as? String
        XCTAssertTrue(replayed?.contains("Shop") == true, replayed ?? "")
        XCTAssertEqual(session.paneId, 3)
        BrowserRecorder.shared.finish(id)
        XCTAssertFalse(BrowserRecorder.shared.isRecording(id))
    }

    func testNothingRecordsWhenTurnedOff() async throws {
        UserDefaults.standard.set(false, forKey: ReplayStore.enabledKey)
        defer { UserDefaults.standard.removeObject(forKey: ReplayStore.enabledKey) }
        let id = UUID()
        let page = page(id)
        try await load(page, URL(string: "fixture-a://a/index.html")!)
        BrowserRecorder.shared.record(entry("browser_navigate", page: id, url: page.url))
        XCTAssertFalse(BrowserRecorder.shared.isRecording(id))
        XCTAssertTrue(BrowserRecorder.shared.store.sessions.isEmpty)
    }
}
