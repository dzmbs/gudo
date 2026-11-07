#if os(iOS)
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class PaneChatViewTests: XCTestCase {
    private struct Fixture {
        let pane: Pane
        let state: PaneChatState
        let backend: PanePresentationTests.Backend
        let events: WorkspaceEventHub
        let client: TimelineFixtureClient
        let window: UIWindow
    }

    func testBothPresentationsRetainTheirNativeViewsWhileTheSharedTimelineAdvances() async throws {
        let suite = "chat-pane-view-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            preferences.removePersistentDomain(forName: suite)
            UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
        }
        for name in ["Dracula", "Apple System Colors Light"] {
            var arguments = saved
            arguments[TerminalPreferences.Key.theme] = name
            arguments[TerminalPreferences.Key.windowTheme] = TerminalPreferences.WindowTheme.auto.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            let fixture = try makeFixture(preferences: preferences)
            defer {
                fixture.state.deactivate()
                fixture.window.isHidden = true
                fixture.window.rootViewController = nil
            }
            try await exercise(fixture, name: name.contains("Light") ? "light" : "dark")
        }
    }

    func testNativeSegmentSelectionVetoKeepsMarkedComposerAndChatSelected() async throws {
        let suite = "chat-pane-marked-test-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fixture = try makeFixture(preferences: preferences)
        defer {
            fixture.state.deactivate()
            fixture.window.isHidden = true
            fixture.window.rootViewController = nil
            preferences.removePersistentDomain(forName: suite)
        }
        try await wait { fixture.state.controller != nil && fixture.state.model?.frame.rows.count == 60 }
        let controller = try XCTUnwrap(fixture.state.controller)
        let editor = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        controller.view.addSubview(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        let picker = try XCTUnwrap(presentationControl(in: fixture.window))
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(fixture.state.presentation, .chat)
        XCTAssertEqual(picker.selectedSegmentIndex, 0)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertNotNil(editor.markedTextRange)
        let update = try TimelineFixtureJSON.update([["Unavailable": ["message": "Fixture Chat stopped"]]])
        fixture.events.deliver(.timeline(paneId: 7, updateJson: update))
        try await wait { fixture.state.model?.error == "Fixture Chat stopped" }
        XCTAssertEqual(fixture.state.presentation, .chat)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertNotNil(editor.markedTextRange)
    }

    private func makeFixture(preferences: UserDefaults) throws -> Fixture {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let backend = PanePresentationTests.Backend()
        let pane = try Pane(id: PaneId(7), backend: backend, appearance: .fromPreferences(), onExit: {})
        pane.view.surface.terminal.write(Array("Private live terminal fixture\r\nOriginal terminal draft stays here".utf8))
        let state = PaneChatState(member: HostPane(hostId: "fixture", pane: pane.id), defaultPresentation: .chat,
                                  agent: .claude, inputPresentation: pane.inputPresentation,
                                  preferences: preferences, pool: ChatModelPool(capacity: 1))
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
        let client = TimelineFixtureClient(snapshot: try TimelineFixtureJSON.snapshot(0..<60, before: nil))
        let events = WorkspaceEventHub()
        let hub = DaemonWorkspace(hostId: "fixture", events: events, resolve: { client })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: ThemedRoot {
            NavigationStack {
                PaneChatView(pane: pane, state: state, hub: hub) { active in
                    NativeTerminalFixture(pane: pane, active: active)
                }
                .navigationTitle("Review the change").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .principal) { PaneChatToggle(pane: pane, state: state) } }
            }
        })
        window.isHidden = false
        return Fixture(pane: pane, state: state, backend: backend, events: events, client: client, window: window)
    }

    private func exercise(_ fixture: Fixture, name: String) async throws {
        let state = fixture.state
        try await wait { state.model?.frame.rows.count == 60 && state.controller?.collection.numberOfSections == 1 }
        try await Task.sleep(for: .milliseconds(180))
        let controller = try XCTUnwrap(state.controller)
        let original = fixture.pane.view
        let originalGrid = original.surface.terminal.size
        XCTAssertEqual(state.presentation, .chat)
        XCTAssertNil(original.superview)
        state.draft = "Unsent Chat draft"
        controller.scrollViewWillBeginDragging(controller.collection)
        controller.collection.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        XCTAssertFalse(try XCTUnwrap(state.model).followsBottom)
        try await Task.sleep(for: .milliseconds(180))
        let reading = try readingAnchor(in: controller.collection)
        try capture(fixture.window, name: "chat-" + name)
        let picker = try XCTUnwrap(presentationControl(in: fixture.window))
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        try await wait { state.presentation == .terminal && original.superview != nil }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(fixture.pane.view === original)
        XCTAssertTrue(state.controller === controller)
        XCTAssertEqual(state.draft, "Unsent Chat draft")
        try capture(fixture.window, name: "terminal-" + name)
        let update = try TimelineFixtureJSON.append("m59", text: "\n\nLive while Terminal is visible.", sequence: 1)
        fixture.events.deliver(.timeline(paneId: 7, updateJson: update))
        try await wait { state.model?.frame.cursor?.sequence == 1 }
        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        try await wait { state.presentation == .chat && original.superview == nil }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(state.controller === controller)
        XCTAssertEqual(try position(of: reading.row, in: controller.collection), reading.position,
                       accuracy: 1, name + " reading anchor")
        XCTAssertEqual(state.draft, "Unsent Chat draft")
        XCTAssertEqual(original.surface.terminal.size.cols, originalGrid.cols)
        XCTAssertEqual(original.surface.terminal.size.rows, originalGrid.rows)
        XCTAssertEqual(fixture.backend.state.withLock { $0.resizes }, 0)
        XCTAssertEqual(fixture.backend.state.withLock { $0.claims }, 0)
        XCTAssertTrue(fixture.backend.state.withLock { $0.input.isEmpty })
        XCTAssertEqual(fixture.client.calls.filter { $0 == "watch 7" }.count, 1)
        XCTAssertFalse(fixture.client.calls.contains("unwatch 7"))
        XCTAssertTrue(fixture.client.state.withLock { $0.launches.isEmpty })
        try capture(fixture.window, name: "returned-chat-" + name)
    }

    private func readingAnchor(in collection: UICollectionView) throws -> (row: ChatRowID, position: CGFloat) {
        let source = try XCTUnwrap(collection.dataSource as? UICollectionViewDiffableDataSource<Int, ChatRowID>)
        let point = CGPoint(x: 1, y: collection.contentOffset.y + collection.adjustedContentInset.top)
        let path = try XCTUnwrap(collection.indexPathForItem(at: point))
        let identifier = try XCTUnwrap(source.itemIdentifier(for: path))
        return (identifier, try position(of: identifier, in: collection))
    }

    private func position(of identifier: ChatRowID, in collection: UICollectionView) throws -> CGFloat {
        let source = try XCTUnwrap(collection.dataSource as? UICollectionViewDiffableDataSource<Int, ChatRowID>)
        let path = try XCTUnwrap(source.indexPath(for: identifier))
        return try XCTUnwrap(collection.layoutAttributesForItem(at: path)).frame.minY - collection.contentOffset.y
    }

    private func presentationControl(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.presentationControl(in: $0) }.first
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Chat pane did not reach its expected state")
        throw CancellationError()
    }

    private func capture(_ window: UIWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try image.pngData()?.write(to: root.appendingPathComponent("\(device)-pane-\(name).png"))
    }
}

private struct NativeTerminalFixture: UIViewRepresentable {
    let pane: Pane
    let active: Bool

    func makeUIView(context: Context) -> TerminalHost.Container {
        let host = TerminalHost.Container()
        host.pane = pane
        host.isActive = active
        pane.hosts.add(host)
        return host
    }

    func updateUIView(_ host: TerminalHost.Container, context: Context) { host.isActive = active }
}

nonisolated private final class TimelineFixtureClient: FakeWorkspaceClient, DaemonTimelineAPI, @unchecked Sendable {
    private let snapshot: String
    init(snapshot: String) { self.snapshot = snapshot; super.init() }
    func timelineWatch(paneId: UInt64) async throws -> String { record("watch \(paneId)"); return snapshot }
    func timelineUnwatch(paneId: UInt64) async throws { record("unwatch \(paneId)") }
    func timelineItemsBefore(paneId: UInt64, before: UInt64, limit: UInt16) async throws -> String {
        try TimelineFixtureJSON.snapshot(0..<0, before: nil)
    }
    func timelineToolOutput(paneId: UInt64, handle: String, offset: UInt64, len: UInt32) async throws -> String {
        try TimelineFixtureJSON.json(["text": "Fixture output", "next_offset": NSNull(), "total_bytes": 14])
    }
}
#endif
