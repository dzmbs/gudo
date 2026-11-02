import Foundation
import XCTest
@testable import App

/// Session Replay's files: the store's size cap and age, `.gudoreplay` round trips, and the
/// Playwright test a session exports as.
@MainActor
final class BrowserReplayTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "replay-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func action(_ id: Int, _ tool: String, _ args: [String: Any], locator: String? = nil, role: String? = nil,
                        name: String? = nil, nth: Int? = nil, ref: String? = nil, after: String? = nil, verdict: String = "done") -> ReplayAction {
        ReplayAction(
            id: id, tool: tool, ref: ref, role: role, name: name, nth: nth, args: BrowserActionEntry.json(args),
            urlBefore: "https://shop.test/", urlAfter: after ?? "https://shop.test/", time: start.addingTimeInterval(Double(id)),
            verdict: verdict, selector: nil, locator: locator)
    }

    private func session(title: String = "Shop", started: Date? = nil) -> ReplaySession {
        var session = ReplaySession(started: started ?? start, title: title, hostId: "h1", paneId: 7)
        session.actions = [
            action(0, "browser_navigate", ["url": "shop.test"], after: "https://shop.test/"),
            action(1, "browser_fill", ["target": ["type": "ref", "ref": "ref_2"], "value": "Ada"], locator: "getByRole('textbox', { name: 'Name' })", role: "textbox", name: "Name"),
            action(2, "browser_click", ["target": ["type": "ref", "ref": "ref_5"]], locator: "getByRole('button', { name: 'Pay now' })"),
        ]
        return session
    }

    func testBundleRoundTripsSessionEventsAndKeyframes() throws {
        let store = ReplayStore(root: root)
        var original = try store.create(session())
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        original.actions[2].keyframe = store.writeKeyframe(jpeg, session: original.id, action: 2)
        try store.save(original)
        XCTAssertTrue(store.append(events: [#"{"data":{},"timestamp":1790000000000,"type":4}"#, #"{"data":{"node":{}},"timestamp":1790000000001,"type":2}"#], to: original.id))
        store.close(original.id)

        let file = try store.bundle(original.id)
        XCTAssertEqual(file, try store.bundle(original.id), "the same session makes the same bytes")
        let other = ReplayStore(root: root.appending(path: "other"))
        let opened = try other.importBundle(file)
        XCTAssertTrue(opened.imported)
        XCTAssertEqual(opened.id, original.id)
        XCTAssertEqual(opened.actions, original.actions)
        XCTAssertEqual(opened.title, "Shop")
        XCTAssertEqual(other.keyframe("k2.jpg", session: opened.id), jpeg)
        XCTAssertEqual(other.eventLines(opened.id).map(String.init), store.eventLines(original.id).map(String.init))
        // Exported again it is the same file.
        XCTAssertEqual(try other.bundle(opened.id), file)
    }

    func testImportRejectsOtherFilesAndUnsafeKeyframeNames() throws {
        let store = ReplayStore(root: root)
        XCTAssertThrowsError(try store.importBundle(Data(#"{"format":"other"}"#.utf8)))
        var hostile = session()
        hostile.actions[0].keyframe = "../../escape.jpg"
        let file = try ReplayStore.bundle(hostile, events: [], keyframes: [("../../escape.jpg", Data([1]))])
        let opened = try store.importBundle(file)
        XCTAssertNil(opened.actions[0].keyframe)
        // Claiming to be a recording of one of this device's panes does not attach it there.
        var claimed = session()
        (claimed.id, claimed.hostId, claimed.paneId) = (UUID(), "host", 7)
        let raw = try JSONSerialization.jsonObject(with: ReplayStore.bundle(claimed, events: [], keyframes: [])) as! [String: Any]
        var forged = raw
        var body = raw["session"] as! [String: Any]
        // Export leaves out which host and pane recorded it.
        XCTAssertNil(body["hostId"] ?? body["paneId"])
        (body["hostId"], body["paneId"]) = ("host", 7)
        forged["session"] = body
        let posing = try store.importBundle(JSONSerialization.data(withJSONObject: forged))
        XCTAssertNil(posing.hostId)
        XCTAssertTrue(store.sessions(hostId: "host", paneId: 7).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appending(path: "escape.jpg").path))
    }

    func testCleanupDropsOldSessionsThenTheOldestBeyondTheCap() throws {
        let store = ReplayStore(root: root, maxAge: 7 * 86_400)
        let now = start.addingTimeInterval(30 * 86_400)
        let expired = try store.create(session(title: "old", started: start))
        let older = try store.create(session(title: "older", started: now.addingTimeInterval(-300)))
        let live = try store.create(session(title: "live", started: now.addingTimeInterval(-250)))
        let newer = try store.create(session(title: "newer", started: now.addingTimeInterval(-200)))
        for id in [older.id, live.id, newer.id] {
            store.append(events: [String(repeating: "x", count: 600)], to: id)
            store.close(id)
        }
        // Room for two of the three.
        store.capacity = store.size(live.id) + store.size(newer.id) + 10
        store.cleanUp(keeping: [live.id], now: now)
        let left = Set(store.sessions.map(\.title))
        XCTAssertFalse(left.contains("old"), "past its age")
        XCTAssertTrue(left.contains("live"), "a session being recorded stays")
        XCTAssertTrue(left.contains("newer"))
        XCTAssertFalse(left.contains("older"), "the oldest goes first")
        XCTAssertLessThanOrEqual(store.totalSize, store.capacity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(expired.id).path))
        XCTAssertEqual(ReplayStore(root: root).sessions.map(\.id), store.sessions.map(\.id), "what is on disk")
    }

    func testEventsStopAtTheSessionCap() throws {
        let store = ReplayStore(root: root, sessionEventCap: 100)
        let made = try store.create(session())
        XCTAssertTrue(store.append(events: [String(repeating: "a", count: 60)], to: made.id))
        XCTAssertFalse(store.append(events: [String(repeating: "b", count: 60)], to: made.id))
        store.close(made.id)
        XCTAssertEqual(store.eventLines(made.id).count, 1)
    }

    func testPlaywrightTestFromLocators() {
        let text = ReplayPlaywright.test(for: session())
        XCTAssertEqual(text, """
        import { test, expect } from '@playwright/test';

        // Recorded 2026-09-21T14:13:20Z by Session Replay.
        test('Shop', async ({ page }) => {
          await page.goto('https://shop.test/');
          await page.getByRole('textbox', { name: 'Name' }).fill('Ada');
          await page.getByRole('button', { name: 'Pay now' }).click();
        });

        """)
        XCTAssertEqual(text, ReplayPlaywright.test(for: session()), "deterministic")
        XCTAssertEqual(ReplayPlaywright.fileName(for: session(title: "Check out: Step 2")), "check-out-step-2.spec.ts")
    }

    func testPlaywrightFallbacksWithoutLocators() {
        var replay = ReplaySession(started: start, title: "It's here")
        replay.actions = [
            action(0, "browser_click", ["target": ["type": "ref", "ref": "ref_4"]], role: "link", name: "Docs", nth: 1),
            action(1, "browser_click", ["target": ["type": "coordinate", "x": 120, "y": 340]]),
            action(2, "browser_hover", ["target": ["type": "ref", "ref": "ref_9"]], ref: "ref_9"),
            action(3, "browser_type", ["text": "a'b\n", "submit": true]),
            action(4, "browser_press", ["keys": "cmd+a Backspace", "repeat": 2]),
            action(5, "browser_fill", ["target": ["type": "ref", "ref": "ref_1"], "value": true], locator: "getByRole('checkbox', { name: 'I agree' })"),
            action(6, "browser_fill", ["target": ["type": "ref", "ref": "ref_2"], "value": "pro"], locator: "getByRole('combobox')", role: "combobox"),
            action(7, "browser_scroll", ["direction": "down", "amount": 2]),
            action(8, "browser_navigate", ["url": "back"], verdict: "did not load"),
        ]
        let lines = ReplayPlaywright.test(for: replay).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("test('It\\'s here', async ({ page }) => {"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("await page.goto") }, ["await page.goto('https://shop.test/');"], "starts where the agent was")
        XCTAssertTrue(lines.contains("await page.getByRole('link', { name: 'Docs', exact: true }).nth(1).click(); // from the element's role and name (no locator was recorded)"))
        XCTAssertTrue(lines.contains("await page.mouse.click(120, 340); // the agent's screenshot coordinates (no element was recorded)"))
        XCTAssertTrue(lines.contains("// browser_hover on ref_9: no locator was recorded for this element."))
        XCTAssertTrue(lines.contains("await page.keyboard.type('a\\'b\\n');"))
        XCTAssertTrue(lines.contains("await page.keyboard.press('Enter');"))
        XCTAssertEqual(lines.filter { $0 == "await page.keyboard.press('Meta+a');" }.count, 2)
        XCTAssertTrue(lines.contains("await page.getByRole('checkbox', { name: 'I agree' }).check();"))
        XCTAssertTrue(lines.contains("await page.getByRole('combobox').selectOption('pro');"))
        XCTAssertTrue(lines.contains("await page.mouse.wheel(0, 200);"))
        XCTAssertTrue(lines.contains("// The agent saw: did not load"))
        XCTAssertEqual(lines.last(where: { !$0.isEmpty }), "});")
    }
}
