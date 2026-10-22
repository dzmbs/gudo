import WebKit
import XCTest
@testable import App

/// The agent's page script on a fixture page: snapshots with refs, what changed after an
/// action, stale refs, secrets never read back, and the steps left to the user.
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
      <button type="button" onclick="this.textContent='Clicked'; document.getElementById('later').hidden = false">More</button>
      <button type="submit">Pay now</button>
    </form>
    <a href="#docs">Docs</a>
    <button id="later" hidden>Appeared</button>
    <p id="out"></p>
    """

    private func page() async throws -> WebPage {
        var configuration = WebPage.Configuration()
        BrowserAgentScript.install(in: configuration.userContentController)
        let page = WebPage(configuration: configuration)
        for try await event in page.load(html: html, baseURL: URL(string: "https://fixture.test/")!) where event == .finished {
            break
        }
        return page
    }

    private func js<T>(_ page: WebPage, _ body: String, _ args: [String: Any] = [:]) async throws -> T {
        let value = try await page.callJavaScript(body, arguments: ["args": args], contentWorld: BrowserAgentScript.world)
        return try XCTUnwrap(value as? T, "\(String(describing: value))")
    }

    func testSnapshotListsControlsWithRefsAndHidesSecrets() async throws {
        let page = try await page()
        let text: String = try await js(page, "return window.__un.snapshot(args)", ["full": true, "filter": "all"])
        XCTAssertTrue(text.hasPrefix("Page: Fixture — https://fixture.test/"), text)
        XCTAssertTrue(text.contains(#"textbox "Name" [ref_"#), text)
        XCTAssertTrue(text.contains(#"checkbox "I agree" (unchecked) [ref_"#), text)
        XCTAssertTrue(text.contains(#"combobox = "Free" [ref_"#) || text.contains(#"combobox"#), text)
        XCTAssertTrue(text.contains(#"button "Pay now" [ref_"#), text)
        XCTAssertTrue(text.contains(#"link "Docs" → #docs [ref_"#), text)
        XCTAssertFalse(text.contains("hunter2"), "a password never leaves the page")
        XCTAssertTrue(text.contains("••••"), text)
        XCTAssertFalse(text.contains("Appeared"), "hidden elements are left out")
    }

    func testActionsAnswerWithWhatChangedAndRefsGoStale() async throws {
        let page = try await page()
        let first: String = try await js(page, "return window.__un.snapshot(args)", ["full": true])
        let more = try XCTUnwrap(first.split(separator: "\n").first { $0.contains(#"button "More""#) })
        let ref = String(try XCTUnwrap(more.split(separator: "[").last?.dropLast()))
        let done: [String: Any] = try await js(page, "return window.__un.act(args)", ["kind": "click", "phase": "do", "target": ["type": "ref", "ref": ref]])
        XCTAssertEqual(done["done"] as? Bool, true, "\(done)")
        let delta: String = try await js(page, "return window.__un.snapshot(args)")
        XCTAssertTrue(delta.contains("Changed since the last snapshot"), delta)
        XCTAssertTrue(delta.contains(#"+ button "Clicked""#), delta)
        XCTAssertTrue(delta.contains(#"+ button "Appeared""#), delta)
        XCTAssertTrue(delta.contains(#"- button "More""#), delta)
        let again: String = try await js(page, "return window.__un.snapshot(args)")
        XCTAssertTrue(again.contains("No change since the last snapshot."), again)

        do {
            let _: [String: Any] = try await js(page, "return window.__un.act(args)", ["kind": "click", "target": ["type": "ref", "ref": "ref_999"]])
            XCTFail("an unknown ref acts on nothing")
        } catch {
            XCTAssertTrue(BrowserAgent.describe(error).contains("ref_999 is stale or not found"), BrowserAgent.describe(error))
        }
    }

    func testTypingFillingAndTheUsersSteps() async throws {
        let page = try await page()
        let text: String = try await js(page, "return window.__un.snapshot(args)", ["full": true])
        func ref(_ needle: String) throws -> String {
            let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains(needle) }, needle)
            return String(try XCTUnwrap(line.split(separator: "[").last?.dropLast()))
        }
        let _: [String: Any] = try await js(page, "return window.__un.act(args)",
                                            ["kind": "type", "phase": "do", "text": "Ana", "target": ["type": "ref", "ref": try ref(#"textbox "Name""#)]])
        let _: [String: Any] = try await js(page, "return window.__un.act(args)",
                                            ["kind": "fill", "phase": "do", "value": true, "target": ["type": "ref", "ref": try ref("I agree")]])
        let _: [String: Any] = try await js(page, "return window.__un.act(args)",
                                            ["kind": "fill", "phase": "do", "value": "Pro", "target": ["type": "ref", "ref": try ref("combobox")]])
        let values: String = try await page.callJavaScript(
            "const v = id => document.getElementById(id); return [v('name').value, v('terms').checked, v('plan').value].join('|')", contentWorld: .page) as? String ?? ""
        XCTAssertEqual(values, "Ana|true|pro")

        let pay: [String: Any] = try await js(page, "return window.__un.act(args)",
                                              ["kind": "click", "target": ["type": "ref", "ref": try ref("Pay now")]])
        let need = try XCTUnwrap(pay["needsUser"] as? [String: Any], "a payment waits for the user")
        XCTAssertEqual(need["kind"] as? String, "approve")
        let password: [String: Any] = try await js(page, "return window.__un.act(args)",
                                                   ["kind": "type", "text": "x", "target": ["type": "ref", "ref": try ref("(password)")]])
        XCTAssertEqual((password["needsUser"] as? [String: Any])?["kind"] as? String, "handoff", "passwords are the user's to type")
        let found: String = try await js(page, "return window.__un.find(args.query)", ["query": "name field"])
        XCTAssertTrue(found.hasPrefix(#"textbox "Name""#), found)
    }

    func testAgentURLs() throws {
        XCTAssertEqual(try BrowserAgent.url("localhost:3000/x").absoluteString, "http://localhost:3000/x")
        XCTAssertEqual(try BrowserAgent.url("example.com").absoluteString, "https://example.com")
        XCTAssertThrowsError(try BrowserAgent.url("file:///etc/passwd"))
    }
}
