#if os(iOS)
import DesignSystem
import GudoCore
import HostKit
import PaneLayout
import SwiftUI
import UIKit
import XCTest
@testable import App

/// Renders the real Chat pane, fed by a fixture timeline, in the scenes a design review compares
/// against: a long reply, a working turn, a draft, an expanded failed call and both empty states,
/// dark and light, on whichever device the simulator is. `TEST_RUNNER_GUDO_CHAT_REVIEW_DIR=<dir>`.
@MainActor
final class ChatReviewCaptureTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["GUDO_CHAT_REVIEW_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        try XCTSkipIf(path == nil, "set TEST_RUNNER_GUDO_CHAT_REVIEW_DIR to capture Chat review scenes")
        directory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testCaptureReviewScenes() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        for (appearance, theme) in [("dark", TerminalPreferences.Default.theme), ("light", ThemePair.resolvedDefaultLight)] {
            var arguments = saved
            arguments[TerminalPreferences.Key.theme] = theme
            arguments[TerminalPreferences.Key.windowTheme] = TerminalPreferences.WindowTheme.auto.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            try await capturePages("long-", appearance: appearance, items: ChatScenes.longTurn())
            try await capturePages("working-", appearance: appearance, items: ChatScenes.workingTurn(), working: true, limit: 1)
            try await capturePages("draft-", appearance: appearance, items: ChatScenes.longTurn(), limit: 1,
                                   draft: "Also check the iPad layout and tell me what changed.")
            try await capturePages("failed-expanded-", appearance: appearance, items: ChatScenes.failedTurn(), limit: 1,
                                   expanding: ChatRowID(item: "failed", part: 0))
            try await capturePages("folded-open-", appearance: appearance, items: ChatScenes.longTurn(), limit: 1, opensSummary: true)
            try await capturePages("composer-", appearance: appearance, items: ChatScenes.workingTurn(), working: true, limit: 1,
                                   draft: "Also check the iPad layout", queued: ["Then run the page checks again"], attaches: true)
            try await capturePages("empty", appearance: appearance, items: [], limit: 1)
            try await capturePages("empty-finding", appearance: appearance, items: [], limit: 1, nativeSession: "")
        }
    }

    // MARK: Scenes

    private func capturePages(_ name: String, appearance: String, items: [[String: Any]], working: Bool = false,
                              limit: Int = 6, draft: String = "", expanding: ChatRowID? = nil,
                              nativeSession: String = "fixture", opensSummary: Bool = false, queued: [String] = [],
                              attaches: Bool = false) async throws {
        let suite = "chat-review-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences, items: items, working: working, nativeSession: nativeSession)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.model?.isLoading == false && fixture.state.controller != nil }
        fixture.state.draft = draft
        if let expanding { fixture.state.model?.toggle(expanding) }
        if opensSummary, let summary = fixture.state.model?.frame.rows.first(where: { ChatTurnCollapse.isSummary($0.id) }) {
            fixture.state.model?.toggle(summary.id)
        }
        for text in queued { fixture.state.queue.enqueue(text) }
        if attaches {
            let file = try ChatPhotoFile.prepare(data: ChatScenes.dashboardPNG(), name: "dashboard.png")
            fixture.state.photos.begin(in: fixture.state)
            fixture.state.photos.load(in: fixture.state, photo: { file }, source: { _ in "/work/uploads/dashboard.jpg" })
            try await wait { fixture.state.photos.attachments.count == 1 }
        }
        try await Task.sleep(for: .milliseconds(900))
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        guard limit > 1, let controller = fixture.state.controller else {
            try capture(fixture.window, named: "\(device)-\(name)\(limit == 1 && name.hasSuffix("-") ? "0" : "")-\(appearance)")
            return
        }
        let collection = controller.collection
        controller.scrollViewWillBeginDragging(collection)
        let page = collection.bounds.height - collection.adjustedContentInset.top - collection.adjustedContentInset.bottom
        let top = -collection.adjustedContentInset.top
        let bottom = max(top, collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        var offset = top
        for index in 0..<limit {
            collection.setContentOffset(CGPoint(x: 0, y: min(offset, bottom)), animated: false)
            controller.scrollViewDidEndDragging(collection, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(500))
            try capture(fixture.window, named: "\(device)-\(name)\(index)-\(appearance)")
            if offset >= bottom { break }
            offset += page * 0.85
            controller.scrollViewWillBeginDragging(collection)
        }
    }

    // MARK: Fixture

    private struct Fixture {
        let state: PaneChatState
        let window: UIWindow
    }

    private func makeFixture(preferences: UserDefaults, items: [[String: Any]], working: Bool,
                             nativeSession: String) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let backend = PanePresentationTests.Backend()
        let pane = try Pane(id: PaneId(7), backend: backend, appearance: .fromPreferences(), onExit: {})
        let state = PaneChatState(member: HostPane(hostId: "fixture", pane: pane.id), defaultPresentation: .chat,
                                  agent: .claude, inputPresentation: pane.inputPresentation,
                                  preferences: preferences, pool: ChatModelPool(capacity: 1), dictation: .init())
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
        let snapshot = try ChatScenes.snapshot(items, nativeSession: nativeSession)
        let client = TimelineFixtureClient(snapshot: snapshot, nativeMessageReceipts: true)
        client.state.withLock { files in
            files.files[ChatScenes.image] = ChatScenes.dashboardPNG()
            files.files[ChatScenes.attachment] = ChatScenes.dashboardPNG()
        }
        let hub = DaemonWorkspace(hostId: "fixture", events: WorkspaceEventHub(), resolve: { client })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ThemedRoot {
            NavigationStack {
                PaneChatView(pane: pane, state: state, hub: hub, permitsSending: true, working: working) { _ in Color.clear }
                    .navigationTitle("Review the change").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .principal) { PaneChatToggle(pane: pane, state: state) } }
                    .chromeBarBackground(.base)
                    .chromeBackground(DS.Palette.base)
            }
        })
        window.makeKeyAndVisible()
        return Fixture(state: state, window: window)
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<3_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Chat did not open", file: file, line: line)
        throw CancellationError()
    }

    private func capture(_ window: UIWindow, named name: String) throws {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
#endif
