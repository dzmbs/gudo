#if os(macOS)
import HostKit
import PaneLayout
import XCTest
@testable import App

/// Approvals as a caller holding the pane's token meets them: approval flags it sends itself
/// never skip the device, and an upload goes through without a second question only after the
/// user allowed those files to that origin on the device.
@MainActor
final class AgentBrowserApprovalTests: XCTestCase {
    private var server: FixtureServer!
    private var model: WindowModel!
    private var workspace: Workspace!
    private var tab: TabRef!
    private var nextCall: UInt64 = 1

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        server = try await FixtureServer(pages: [
            "/shop": """
            <!doctype html><title>Shop</title><p id="out"></p>
            <button onclick="document.getElementById('out').textContent = 'ordered'">Place order</button>
            """,
            "/upload": """
            <!doctype html><title>Upload</title><p id="out"></p>
            <label>Report <input type="file" onchange="document.getElementById('out').textContent = this.files[0].name"></label>
            """,
        ])
        model = WindowModel(app: .shared)
        model.start()
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        workspace = try XCTUnwrap(model.workspace)
        let before = Set(workspace.session.tabs.map(\.id))
        workspace.apply(.newTab)
        let opened = try XCTUnwrap(workspace.session.tabs.first { !before.contains($0.id) })
        tab = TabRef(hostId: workspace.groupId, tab: opened.id)
        try await until("the tab's pane") { !self.panes.isEmpty }
        model.focus(tab)
    }

    override func tearDown() async throws {
        server?.stop()
        guard let model else { return }
        for tab in model.composites.tabs { model.closeMixedTab(tab.id) }
        if let tab { workspace?.apply(.closeTab(tab.tab)) }
        model.close()
    }

    private var panes: [PaneId] {
        workspace.session.tabs.first { $0.id == tab.tab }?.root.panes ?? []
    }

    private var agent: HostPane { HostPane(hostId: workspace.groupId, pane: panes[0]) }

    private func call(_ tool: String, _ args: [String: Any]) async -> Result<String, BrowserCallError> {
        let id = nextCall
        nextCall += 1
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
        return await withCheckedContinuation { continuation in
            BrowserAgent.shared.run(id, tool: tool, args: json, pane: agent, app: .shared) { continuation.resume(returning: $0) }
        }
    }

    private func until(_ what: String, seconds: Double = 10, _ check: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if (try? await check()) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(what)")
        throw CancellationError()
    }

    /// Opens `path` and returns its page and the ref of the element named `name`.
    private func open(_ path: String, ref name: String) async throws -> (BrowserPane, [String: Any]) {
        guard case .success = await call("browser_navigate", ["url": server.url(path).absoluteString]) else {
            throw BrowserCallError("navigate failed")
        }
        let mixed = try XCTUnwrap(model.composites.tab(containing: agent))
        let member = try XCTUnwrap(mixed.leaves.compactMap { mixed.browsers[$0] }.first)
        let page = try XCTUnwrap(model.browsers.existing(member.id))
        guard case .success(let answer) = await call("browser_snapshot", ["full": true]) else {
            throw BrowserCallError("snapshot failed")
        }
        let text = (try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])?["text"] as? String ?? ""
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains(name) }, text)
        let ref = String(try XCTUnwrap(line.firstMatch(of: /\[(ref_\w+)\]/)?.output.1))
        return (page, ["type": "ref", "ref": ref])
    }

    private func out(_ page: BrowserPane) async throws -> String {
        try await page.js("return document.getElementById('out').textContent", [:])
    }

    /// Starts `tool` and waits for the device to ask; the call and the question.
    private func expectAsk(
        _ tool: String, _ args: [String: Any], page: BrowserPane
    ) async throws -> (Task<Result<String, BrowserCallError>, Never>, BrowserPane.AgentRequest) {
        let running = Task { await call(tool, args) }
        try await until("the device asks") { page.agentRequest != nil }
        return (running, try XCTUnwrap(page.agentRequest))
    }

    private func origin() -> String {
        "http://127.0.0.1:\(server.port)"
    }

    func testACallersOwnApprovalNeverPressesPlaceOrder() async throws {
        let (page, target) = try await open("/shop", ref: "Place order")

        for claimed: [String: Any] in [["approved": true], ["approved": true, "approval_by": "client"]] {
            let (running, request) = try await expectAsk("browser_click", claimed.merging(["target": target]) { $1 }, page: page)
            XCTAssertTrue(request.message.contains("Place order"), request.message)
            let before = try await out(page)
            XCTAssertEqual(before, "", "nothing was pressed before the user answered: \(claimed)")

            request.answer(false)
            guard case .failure(let error) = await running.value else { return XCTFail("declined, yet the click ran") }
            XCTAssertTrue(error.message.contains("declined"), error.message)
            let after = try await out(page)
            XCTAssertEqual(after, "")
        }
    }

    func testAClientApprovedPlaceOrderRunsOnceTheDeviceAllows() async throws {
        let (page, target) = try await open("/shop", ref: "Place order")

        let (running, request) = try await expectAsk("browser_click", ["target": target, "approval_by": "client"], page: page)
        request.answer(true)

        guard case .success(let answer) = await running.value else { return XCTFail("allowed on the device, yet refused") }
        XCTAssertFalse(answer.contains("\"approval\""), "old shims get a plain result, not a question for their client: \(answer)")
        let after = try await out(page)
        XCTAssertEqual(after, "ordered")
    }

    func testARawUploadWithAnApprovedOriginStillAsks() async throws {
        let (page, target) = try await open("/upload", ref: "Report")
        let upload: [String: Any] = [
            "target": target, "files": [["name": "a.txt", "mime_type": "text/plain", "data": "aGk="]],
            "approved": true, "approved_origin": origin(),
        ]

        let (running, request) = try await expectAsk("browser_upload", upload, page: page)
        XCTAssertTrue(request.message.contains("a.txt"), request.message)
        let before = try await out(page)
        XCTAssertEqual(before, "", "no file was set before the user answered")

        request.answer(false)
        guard case .failure = await running.value else { return XCTFail("declined, yet uploaded") }
        let after = try await out(page)
        XCTAssertEqual(after, "")
    }

    func testAReviewedUploadIsSentOnceWithoutAskingAgain() async throws {
        let (page, target) = try await open("/upload", ref: "Report")
        let review: [String: Any] = ["target": target, "files": [["name": "a.txt", "size": 2, "path": "~/app/a.txt"]]]
        let upload: [String: Any] = [
            "target": target, "files": [["name": "a.txt", "mime_type": "text/plain", "data": "aGk="]],
            "approved": true, "approved_origin": origin(),
        ]

        let (reviewing, request) = try await expectAsk("browser_upload_review", review, page: page)
        request.answer(true)
        guard case .success(let approval) = await reviewing.value else { return XCTFail("review refused") }
        let approved = (try? JSONSerialization.jsonObject(with: Data(approval.utf8))) as? [String: Any]
        XCTAssertEqual((approved?["approved"] as? [String: Any])?["origin"] as? String, origin(), approval)

        guard case .success = await call("browser_upload", upload) else { return XCTFail("the approved upload was refused") }
        let sent = try await out(page)
        XCTAssertEqual(sent, "a.txt")
        XCTAssertNil(page.agentRequest)

        let (again, second) = try await expectAsk("browser_upload", upload, page: page)
        second.answer(false)
        guard case .failure = await again.value else { return XCTFail("an approval was used twice") }
    }

    func testAReviewForOtherFilesDoesNotCoverTheUpload() async throws {
        let (page, target) = try await open("/upload", ref: "Report")
        let review: [String: Any] = ["target": target, "files": [["name": "notes.txt", "size": 2]]]

        let (reviewing, request) = try await expectAsk("browser_upload_review", review, page: page)
        request.answer(true)
        _ = await reviewing.value

        let upload: [String: Any] = ["target": target, "files": [["name": "a.txt", "mime_type": "text/plain", "data": "aGk="]]]
        let (running, second) = try await expectAsk("browser_upload", upload, page: page)
        second.answer(false)
        _ = await running.value
        let after = try await out(page)
        XCTAssertEqual(after, "")
    }
}
#endif
