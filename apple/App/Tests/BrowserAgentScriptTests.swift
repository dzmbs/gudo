import WebKit
import XCTest
@testable import App

/// The agent's page script on fixture pages: snapshots with refs from Playwright's aria tree,
/// what changed after an action, refs found again after a re-render, actions that wait for
/// their target or say what covers it, effects, secrets never read back, and the steps left
/// to the user.
@MainActor
final class BrowserAgentScriptTests: XCTestCase {
    private let html = """
    <!doctype html><title>Fixture</title>
    <h1>Sign up</h1>
    <form onsubmit="event.preventDefault(); document.getElementById('out').textContent = 'sent ' + document.getElementById('name').value">
      <label for="name">Name</label><input id="name" placeholder="Your name">
      <label>Password <input id="pw" type="password" value="hunter2"></label>
      <label><input id="terms" type="checkbox"> I agree</label>
      <select id="plan"><option value="free">Free</option><option value="pro">Pro</option></select>
      <input id="when" type="date">
      <button type="button" onclick="this.textContent='Clicked'; document.getElementById('later').hidden = false">More</button>
      <button type="submit">Pay now</button>
    </form>
    <a href="#docs">Docs</a>
    <button id="later" hidden>Appeared</button>
    <div id="card" style="cursor:pointer" onclick="this.textContent='opened'">Open card</div>
    <button id="inert">Does nothing</button>
    <button id="off" disabled>Off</button>
    <div style="position:relative"><button id="under">Under</button><div id="cookie-banner" style="position:absolute;inset:0;background:#fff">We use cookies</div></div>
    <div id="list"><button class="item" onclick="this.dataset.n = (+this.dataset.n || 0) + 1">Save</button></div>
    <div id="editor" contenteditable="true"></div>
    <p id="out"></p>
    """

    private func page(_ html: String? = nil) async throws -> WebPage {
        var configuration = WebPage.Configuration()
        BrowserAgentScript.install(in: configuration.userContentController)
        let page = WebPage(configuration: configuration)
        for try await event in page.load(html: html ?? self.html, baseURL: URL(string: "https://fixture.test/")!) where event == .finished {
            break
        }
        return page
    }

    private func js<T>(_ page: WebPage, _ body: String, _ args: [String: Any] = [:]) async throws -> T {
        let value = try await page.callJavaScript(body, arguments: ["args": args], contentWorld: BrowserAgentScript.world)
        return try XCTUnwrap(value as? T, "\(String(describing: value))")
    }

    private func value(_ page: WebPage, _ expression: String) async throws -> String {
        try await page.callJavaScript("const $ = id => document.getElementById(id); return String(\(expression))", contentWorld: .page) as? String ?? ""
    }

    private func ref(_ text: String, _ needle: String) throws -> String {
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains(needle) }, "\(needle) in\n\(text)")
        let match = try XCTUnwrap(line.firstMatch(of: /\[(ref_\d+)\]/), String(line))
        return String(match.output.1)
    }

    @discardableResult
    private func act(_ page: WebPage, _ args: [String: Any]) async throws -> [String: Any] {
        var input = args
        input["phase"] = "do"
        return try await js(page, "return window.__un.act(args)", input)
    }

    func testSnapshotListsControlsWithRefsAndHidesSecrets() async throws {
        let page = try await page()
        let text: String = try await js(page, "return window.__un.snapshot(args)", ["full": true, "filter": "all"])
        XCTAssertTrue(text.hasPrefix("Page: Fixture — https://fixture.test/"), text)
        XCTAssertTrue(text.contains(#"heading "Sign up" (level=1)"#), text)
        XCTAssertTrue(text.contains(#"textbox "Name" placeholder="Your name" [ref_"#) || text.contains(#"textbox "Name" [ref_"#), text)
        XCTAssertTrue(text.contains(#"checkbox "I agree" (unchecked) [ref_"#), text)
        XCTAssertTrue(text.contains(#"combobox = "Free""#), text)
        XCTAssertTrue(text.contains(#"button "Pay now" [ref_"#), text)
        XCTAssertTrue(text.contains(#"link "Docs" → #docs [ref_"#), text)
        XCTAssertTrue(text.contains("[cursor=pointer]: Open card"), "a clickable div is a target too\n\(text)")
        XCTAssertTrue(text.contains(#"button "Off" (disabled)"#), text)
        XCTAssertFalse(text.contains("hunter2"), "a password never leaves the page")
        XCTAssertTrue(text.contains("••••"), text)
        XCTAssertFalse(text.contains("Appeared"), "hidden elements are left out")

        let interactive: String = try await js(page, "return window.__un.snapshot(args)", ["full": true])
        XCTAssertFalse(interactive.contains("heading"), "interactive lists controls only\n\(interactive)")
        XCTAssertTrue(interactive.contains(#"button "More" [ref_"#), interactive)
    }

    func testActionsAnswerWithWhatChangedAndRefsGoStale() async throws {
        let page = try await page()
        let first: String = try await js(page, "return window.__un.snapshot(args)", ["full": true])
        let more = try ref(first, #"button "More""#)
        let done = try await act(page, ["kind": "click", "target": ["type": "ref", "ref": more], "id": "a1"])
        XCTAssertEqual(done["done"] as? Bool, true, "\(done)")
        let target = try XCTUnwrap(done["target"] as? [String: Any])
        XCTAssertEqual(target["role"] as? String, "button")
        XCTAssertEqual(target["name"] as? String, "More")
        XCTAssertEqual(target["locator"] as? String, "getByRole('button', { name: 'More' })")
        let effect: [String: Any] = try await js(page, "return window.__un.effect(args.id)", ["id": "a1"])
        XCTAssertFalse((effect["changes"] as? [String] ?? []).isEmpty, "\(effect)")

        let delta: String = try await js(page, "return window.__un.snapshot(args)")
        XCTAssertTrue(delta.contains("Changed since the last snapshot"), delta)
        XCTAssertTrue(delta.contains(#"+ button "Clicked" [\#(more)]"#), "the same element keeps its ref\n\(delta)")
        XCTAssertTrue(delta.contains(#"* button "Appeared""#), "a new element is marked\n\(delta)")
        XCTAssertTrue(delta.contains(#"- button "More""#), delta)
        let again: String = try await js(page, "return window.__un.snapshot(args)")
        XCTAssertTrue(again.contains("No change since the last snapshot."), again)

        do {
            try await act(page, ["kind": "click", "target": ["type": "ref", "ref": "ref_999"]])
            XCTFail("an unknown ref acts on nothing")
        } catch {
            XCTAssertTrue(BrowserAgent.describe(error).contains("ref_999 is stale or not found"), BrowserAgent.describe(error))
        }
    }

    func testARerenderedElementIsFoundAgainByRoleAndName() async throws {
        let page = try await page()
        let text: String = try await js(page, "return window.__un.snapshot(args)", ["full": true])
        let save = try ref(text, #"button "Save""#)
        _ = try await page.callJavaScript("document.getElementById('list').innerHTML = '<button class=item onclick=\"this.dataset.n = 1\">Save</button>'", contentWorld: .page)
        let done = try await act(page, ["kind": "click", "target": ["type": "ref", "ref": save]])
        XCTAssertTrue((done["note"] as? String ?? "").contains("found it again"), "\(done)")
        let clicked = try await value(page, "document.querySelector('.item').dataset.n")
        XCTAssertEqual(clicked, "1")
    }

    func testActionsWaitForTheirTargetAndSayWhatCoversIt() async throws {
        let page = try await page()
        let text: String = try await js(page, "return window.__un.snapshot(args)", ["full": true, "filter": "all"])
        do {
            try await act(page, ["kind": "click", "target": ["type": "ref", "ref": try ref(text, #"button "Under""#)]])
            XCTFail("a covered button is not clicked")
        } catch {
            let why = BrowserAgent.describe(error)
            XCTAssertTrue(why.contains("is covered by") && why.contains("cookie-banner"), why)
        }
        do {
            try await act(page, ["kind": "click", "target": ["type": "ref", "ref": try ref(text, #"button "Off""#)]])
            XCTFail("a disabled button is not clicked")
        } catch {
            XCTAssertTrue(BrowserAgent.describe(error).contains("is disabled"), BrowserAgent.describe(error))
        }
        // A button that does nothing: the action runs, and nothing changed.
        let inert = try ref(text, #"button "Does nothing""#)
        try await act(page, ["kind": "click", "target": ["type": "ref", "ref": inert], "id": "n1"])
        _ = try? await Task.sleep(for: .milliseconds(100))
        let effect: [String: Any] = try await js(page, "return window.__un.effect(args.id)", ["id": "n1"])
        XCTAssertEqual(effect["changes"] as? [String], [], "\(effect)")
        XCTAssertTrue(BrowserAgent.noEffect("click", intercepted: nil).contains("browser_press"))
    }

    func testTypingFillingAndTheUsersSteps() async throws {
        let page = try await page()
        let text: String = try await js(page, "return window.__un.snapshot(args)", ["full": true, "filter": "all"])
        // Typing goes key by key: the page sees keydown and input for each.
        _ = try await page.callJavaScript("window.keys = 0; document.getElementById('name').addEventListener('keydown', () => keys++)", contentWorld: .page)
        try await act(page, ["kind": "type", "text": "Ana", "target": ["type": "ref", "ref": try ref(text, #"textbox "Name""#)]])
        try await act(page, ["kind": "fill", "value": true, "target": ["type": "ref", "ref": try ref(text, "I agree")]])
        try await act(page, ["kind": "fill", "value": "Pro", "target": ["type": "ref", "ref": try ref(text, "combobox")]])
        try await act(page, ["kind": "fill", "value": "2026-10-23", "target": ["type": "ref", "ref": try dateRef(text)]])
        let values = try await value(page, "[$('name').value, $('terms').checked, $('plan').value, $('when').value, keys].join('|')")
        XCTAssertEqual(values, "Ana|true|pro|2026-10-23|3")
        try await act(page, ["kind": "fill", "value": "Bea", "target": ["type": "ref", "ref": try ref(text, #"textbox "Name""#)]])
        let replaced = try await value(page, "$('name').value")
        XCTAssertEqual(replaced, "Bea", "fill replaces what was there")

        let pay = try await js(page, "return window.__un.act(args)", ["kind": "click", "target": ["type": "ref", "ref": try ref(text, "Pay now")]]) as [String: Any]
        let need = try XCTUnwrap(pay["needsUser"] as? [String: Any], "a payment waits for the user")
        XCTAssertEqual(need["kind"] as? String, "approve")
        let password: [String: Any] = try await js(page, "return window.__un.act(args)",
                                                   ["kind": "type", "text": "x", "target": ["type": "ref", "ref": try ref(text, "(password)")]])
        XCTAssertEqual((password["needsUser"] as? [String: Any])?["kind"] as? String, "handoff", "passwords are the user's to type")
        let found: String = try await js(page, "return window.__un.find(args.query)", ["query": "name field"])
        XCTAssertTrue(found.hasPrefix(#"textbox "Name""#), found)
    }

    private func dateRef(_ text: String) throws -> String {
        let lines = text.split(separator: "\n").filter { $0.contains("textbox") && !$0.contains("Name") && !$0.contains("password") }
        let line = try XCTUnwrap(lines.first, text)
        return String(try XCTUnwrap(line.firstMatch(of: /\[(ref_\d+)\]/)).output.1)
    }

    func testKeysTypeIntoContentEditableAndEnterSubmits() async throws {
        let page = try await page()
        _ = try await page.callJavaScript("document.getElementById('editor').focus()", contentWorld: .page)
        try await act(page, ["kind": "type", "text": "hi there"])
        let typed = try await value(page, "$('editor').textContent")
        XCTAssertEqual(typed, "hi there")
        // A search form (no password, so nothing waits for the user).
        let search = try await self.page("<title>Search</title><form onsubmit=\"event.preventDefault(); out.textContent = 'sent ' + q.value\"><input id=q aria-label=Query><button>Go</button></form><p id=out></p>")
        let form: String = try await js(search, "return window.__un.snapshot(args)", ["full": true])
        try await act(search, ["kind": "type", "text": "Cy", "submit": true, "target": ["type": "ref", "ref": try ref(form, #"textbox "Query""#)]])
        let out = try await value(search, "$('out').textContent")
        XCTAssertEqual(out, "sent Cy", "Enter in a field submits its form")
    }

    func testAgentURLs() throws {
        XCTAssertEqual(try BrowserAgent.url("localhost:3000/x").absoluteString, "http://localhost:3000/x")
        XCTAssertEqual(try BrowserAgent.url("example.com").absoluteString, "https://example.com")
        XCTAssertThrowsError(try BrowserAgent.url("file:///etc/passwd"))
    }
}
