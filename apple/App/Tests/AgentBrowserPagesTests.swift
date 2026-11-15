#if os(macOS)
import HostKit
import PaneLayout
import XCTest
@testable import App

/// The browser tools as several agents in one tab meet them: each agent pane has a current page
/// of its own, a page closed under it is an error that says so, and one popup is one tab.
@MainActor
final class AgentBrowserPagesTests: XCTestCase {
    private var server: FixtureServer!
    private var model: WindowModel!
    private var workspace: Workspace!
    private var tab: TabRef!
    private var nextCall: UInt64 = 1

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        server = try await FixtureServer(pages: [
            "/one": "<!doctype html><title>One</title><h1>One</h1>",
            "/two": "<!doctype html><title>Two</title><h1>Two</h1>",
            "/popups": "<!doctype html><title>Popups</title><a href=\"/one\" target=\"_blank\">New tab link</a>",
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
        XCTAssertTrue(AppModel.shared.window(forHost: workspace.groupId) === model, "the tools reach this window")
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

    private func agent(_ index: Int = 0) -> HostPane {
        HostPane(hostId: workspace.groupId, pane: panes[index])
    }

    private var pages: [BrowserMember] {
        guard let mixed = model.composites.tab(containing: agent()) else { return [] }
        return mixed.leaves.compactMap { mixed.browsers[$0] }
    }

    private func call(_ tool: String, _ args: [String: Any] = [:], from pane: HostPane) async -> Result<String, BrowserCallError> {
        let id = nextCall
        nextCall += 1
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8), as: UTF8.self)
        let result = await withCheckedContinuation { continuation in
            BrowserAgent.shared.run(id, tool: tool, args: json, pane: pane, app: .shared) { continuation.resume(returning: $0) }
        }
        return result.map { answer in
            let object = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any]
            return object?["text"] as? String ?? ""
        }
    }

    private func text(_ tool: String, _ args: [String: Any] = [:], from pane: HostPane) async throws -> String {
        switch await call(tool, args, from: pane) {
        case .success(let text): return text
        case .failure(let error): XCTFail("\(tool): \(error.message)"); throw error
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

    func testEachAgentPaneDrivesItsOwnPage() async throws {
        workspace.apply(.split(panes[0], .horizontal))
        try await until("a second pane") { self.panes.count == 2 }
        let first = agent(0), second = agent(1)

        _ = try await text("browser_navigate", ["url": server.url("/one").absoluteString], from: first)
        _ = try await text("browser_navigate", ["url": server.url("/two").absoluteString], from: second)

        XCTAssertEqual(pages.count, 2, "the second agent opened a page of its own")
        let snapshot = try await text("browser_snapshot", ["full": true], from: first)
        XCTAssertTrue(snapshot.contains("One"), "the first agent's page is still its own: \(snapshot)")
    }

    func testAClosedCurrentPageIsAnErrorThatSaysWhoClosedItAndWhatIsOpen() async throws {
        _ = try await text("browser_navigate", ["url": server.url("/one").absoluteString], from: agent())
        let mine = try XCTUnwrap(pages.first)
        let mixed = try XCTUnwrap(model.composites.tab(containing: agent()))
        model.composites.addBrowser(BrowserMember(hostId: nil, url: server.url("/two").absoluteString), to: mixed.id)
        model.closeBrowser(mine.id)

        let result = await call("browser_snapshot", from: agent())

        guard case .failure(let error) = result else { return XCTFail("the snapshot moved to another page: \(result)") }
        XCTAssertTrue(error.message.hasPrefix("page_closed"), error.message)
        XCTAssertTrue(error.message.contains("the user"), error.message)
        XCTAssertTrue(error.message.contains("/two"), "names the pages still open: \(error.message)")
    }

    func testSwitchingWithoutATabIdSaysItIsMissing() async throws {
        _ = try await text("browser_navigate", ["url": server.url("/one").absoluteString], from: agent())

        let result = await call("browser_tabs", ["action": "switch"], from: agent())

        guard case .failure(let error) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(error.message.contains("tab_id"), error.message)
    }

    func testOnePopupClickOpensOneTab() async throws {
        _ = try await text("browser_navigate", ["url": server.url("/popups").absoluteString], from: agent())
        let snapshot = try await text("browser_snapshot", ["full": true], from: agent())
        let line = try XCTUnwrap(snapshot.split(separator: "\n").first { $0.contains("New tab link") }, snapshot)
        let ref = String(try XCTUnwrap(line.firstMatch(of: /\[(ref_\w+)\]/)?.output.1))

        _ = try await text("browser_click", ["target": ["type": "ref", "ref": ref]], from: agent())
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(pages.count, 2, "the opener and one popup")
    }
}
#endif
