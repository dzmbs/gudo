import DesignSystem
import HostKit
import Observation
import PaneLayout
import SwiftUI
import XCTest
@testable import App
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Two agent panes in one window, shown one at a time as a tab switch or the iPhone's one pane
/// shows them, sharing one Chat model pool.
@MainActor
final class ChatPaneSwitchFixture {
    @MainActor @Observable final class Selection {
        var pane: PaneId
        init(_ pane: PaneId) { self.pane = pane }
    }

    private struct Harness: View {
        let panes: [Pane]
        let states: [PaneChatState]
        let hub: DaemonWorkspace
        @Bindable var selection: Selection

        var body: some View {
            if let index = panes.firstIndex(where: { $0.id == selection.pane }) {
                PaneChatView(pane: panes[index], state: states[index], hub: hub, permitsSending: true) { _ in
                    Text("Terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .id(panes[index].id)
            }
        }
    }

    let panes: [Pane]
    let states: [PaneChatState]
    let client: TimelineFixtureClient
    let events: WorkspaceEventHub
    let hub: DaemonWorkspace
    let selection: Selection
    let preferences: UserDefaults
    #if canImport(UIKit)
    let window: UIWindow
    #else
    let window: NSWindow
    #endif
    private let suite: String

    init(snapshot: String = "", session: [[String: Any]]? = nil, latency: Duration = .zero,
         pool: ChatModelPool = ChatModelPool(capacity: 2)) throws {
        suite = "chat-pane-switch-" + UUID().uuidString
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = preferences
        panes = try [PaneId(7), PaneId(8)].map { id in
            #if canImport(UIKit)
            try Pane(id: id, backend: PanePresentationTests.Backend(), appearance: .fromPreferences(), onExit: {})
            #else
            try Pane(id: id, backend: MacChatFixture.Backend(), appearance: .fromPreferences(), onExit: {})
            #endif
        }
        states = panes.map { pane in
            let state = PaneChatState(member: HostPane(hostId: "fixture", pane: pane.id), defaultPresentation: .chat,
                                      agent: .claude, inputPresentation: pane.inputPresentation,
                                      preferences: preferences, pool: pool, dictation: .init())
            state.prepareInitialPresentation { pane.prepareToParkTerminal() }
            return state
        }
        let client = TimelineFixtureClient(snapshot: snapshot, nativeMessageReceipts: true)
        client.session = session
        client.latency = latency
        self.client = client
        events = WorkspaceEventHub()
        hub = DaemonWorkspace(hostId: "fixture", events: events, resolve: { client })
        selection = Selection(panes[0].id)
        let root = ThemedRoot { [panes, states, hub, selection] in
            Harness(panes: panes, states: states, hub: hub, selection: selection)
        }
        #if canImport(UIKit)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        #else
        let frame = NSRect(x: -30000, y: -30000, width: 900, height: 760)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The window's size never follows the pane's content, as in a tab.
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        window.contentViewController = host
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        #endif
    }

    func state(_ index: Int) -> PaneChatState { states[index] }

    func show(_ index: Int) { selection.pane = panes[index].id }

    /// The rows on screen in the shown pane's transcript, top to bottom.
    func visibleRows(_ index: Int) -> [ChatRowID] {
        #if canImport(UIKit)
        guard let controller = states[index].controller, controller.view.window != nil else { return [] }
        return controller.collection.indexPathsForVisibleItems.sorted().compactMap(controller.rowID(at:))
        #else
        guard let controller = states[index].controller, controller.view.window != nil else { return [] }
        return controller.visibleRows
        #endif
    }

    /// Where the row starts in the shown pane's reading area.
    func viewportPosition(_ index: Int, of row: ChatRowID) -> CGFloat? {
        states[index].controller?.viewportPosition(of: row)
    }

    /// The shown pane's transcript is scrolled to its first row.
    func atTop(_ index: Int) -> Bool {
        guard let first = states[index].model?.frame.rows.first?.id, let position = viewportPosition(index, of: first) else { return false }
        return position >= -1
    }

    /// Scrolls the shown pane's transcript up by `distance` points, as a reader does.
    func scrollUp(_ index: Int, by distance: CGFloat) async {
        #if canImport(UIKit)
        guard let controller = states[index].controller else { return }
        let collection = controller.collection
        controller.scrollViewWillBeginDragging(collection)
        collection.setContentOffset(CGPoint(x: 0, y: max(0, collection.contentOffset.y - distance)), animated: false)
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        #else
        await window.scrollChat(by: Int32(distance / 4), steps: 4)
        #endif
    }

    func close() {
        for state in states { state.deactivate() }
        #if canImport(UIKit)
        window.isHidden = true
        window.rootViewController = nil
        #else
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        #endif
        preferences.removePersistentDomain(forName: suite)
    }

    /// Waits for `condition`, checking about every millisecond, and returns how long it took.
    @discardableResult
    func wait(timeout: Duration = .seconds(20), file: StaticString = #filePath, line: UInt = #line,
              _ condition: () -> Bool) async throws -> Duration {
        let start = ContinuousClock.now
        while !condition() {
            guard ContinuousClock.now - start < timeout else {
                XCTFail("Chat did not reach its expected state", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return ContinuousClock.now - start
    }
}

@MainActor
final class ChatPaneSwitchTests: XCTestCase {
    /// The first frame with content after switching back to a pane whose Chat was open recently.
    /// The kept transcript adds nothing to it; it is the pane's own SwiftUI views (composer,
    /// overlays) being built again, 59-67 ms on both platforms (docs/PERFORMANCE.md).
    static let switchBudget: Duration = .milliseconds(100)
    #if canImport(UIKit)
    static let platform = "iOS"
    #else
    static let platform = "Mac"
    #endif

    func testSwitchingBackShowsTheSameTranscriptWhereTheReaderLeftIt() async throws {
        let fixture = try ChatPaneSwitchFixture(snapshot: ChatScenes.snapshot(ChatScenes.session(turns: 40)))
        defer { fixture.close() }
        try await fixture.wait { fixture.visibleRows(0).count > 1 }
        await fixture.scrollUp(0, by: 600)
        try await fixture.wait { fixture.state(0).model?.followsBottom == false }
        try await Task.sleep(for: .milliseconds(200))
        let reading = fixture.visibleRows(0)
        let controller = try XCTUnwrap(fixture.state(0).controller)

        fixture.show(1)
        try await fixture.wait { !fixture.visibleRows(1).isEmpty }
        fixture.show(0)
        try await fixture.wait { !fixture.visibleRows(0).isEmpty }

        XCTAssertTrue(fixture.state(0).controller === controller, "the pane's transcript is kept while it is away")
        XCTAssertEqual(fixture.visibleRows(0).first, reading.first, "the reader's row stays at the top")
        XCTAssertEqual(fixture.state(0).model?.followsBottom, false)
    }

    func testAPaneStartedAheadOpensOnRowsAlreadyLoaded() async throws {
        let fixture = try ChatPaneSwitchFixture(session: ChatScenes.session(turns: 20), latency: .milliseconds(80))
        defer { fixture.close() }
        try await fixture.wait { !fixture.visibleRows(0).isEmpty }
        fixture.state(1).prewarm(in: fixture.hub)
        try await fixture.wait { fixture.state(1).model?.frame.rows.isEmpty == false }
        let prewarmed = try XCTUnwrap(fixture.state(1).model)
        fixture.show(1)
        try await fixture.wait { !fixture.visibleRows(1).isEmpty }
        XCTAssertTrue(fixture.state(1).model === prewarmed, "the pane shows the model started ahead")
        XCTAssertEqual(fixture.client.calls.filter { $0 == "watch 8" }.count, 1, "showing it asked for nothing again")
    }

    func testAPaneStartedAheadButNotShownLetsGoAndTakesNoOtherPanesModel() async throws {
        let pool = ChatModelPool(capacity: 2)
        let fixture = try ChatPaneSwitchFixture(session: ChatScenes.session(turns: 4), pool: pool)
        defer { fixture.close() }
        try await fixture.wait { !fixture.visibleRows(0).isEmpty }
        fixture.state(1).prewarm(in: fixture.hub, grace: .milliseconds(50))
        XCTAssertNotNil(fixture.state(1).model)
        try await fixture.wait { fixture.state(1).model == nil }
        try await fixture.wait { fixture.client.calls.contains("unwatch 8") }

        let full = ChatModelPool(capacity: 1)
        let other = PaneChatState(member: HostPane(hostId: "fixture", pane: PaneId(9)), defaultPresentation: .chat,
                                  agent: .claude, preferences: fixture.preferences, pool: full)
        other.activate(in: fixture.hub)
        other.deactivate()
        let hovered = PaneChatState(member: HostPane(hostId: "fixture", pane: PaneId(10)), defaultPresentation: .chat,
                                    agent: .claude, preferences: fixture.preferences, pool: full)
        hovered.prewarm(in: fixture.hub)
        XCTAssertNil(hovered.model, "a pointer passing over a tab does not evict a warm pane")
        XCTAssertEqual(full.warmCount, 1)
    }

    func testMemoryPressureDropsOnlyThePanesNotShown() async throws {
        let pool = ChatModelPool(capacity: 2)
        let fixture = try ChatPaneSwitchFixture(session: ChatScenes.session(turns: 4), pool: pool)
        defer { fixture.close() }
        try await fixture.wait { !fixture.visibleRows(0).isEmpty }
        fixture.show(1)
        try await fixture.wait { !fixture.visibleRows(1).isEmpty }
        XCTAssertEqual(pool.warmCount, 2)
        pool.releaseIdle()
        XCTAssertEqual(pool.warmCount, 1)
        XCTAssertNotNil(fixture.state(1).model)
    }

    /// Switching between two long sessions. Timing runs only on request (`TEST_RUNNER_GUDO_CHAT_PERF=1`).
    func testSwitchingBackToARecentPaneIsWithinBudget() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GUDO_CHAT_PERF"] == nil, "timing runs on request")
        let fixture = try ChatPaneSwitchFixture(snapshot: ChatScenes.snapshot(ChatScenes.session(turns: 300)))
        defer { fixture.close() }
        try await fixture.wait(timeout: .seconds(60)) { !fixture.visibleRows(0).isEmpty }
        let footprint = ProcessStats.footprintMB
        fixture.show(1)
        try await fixture.wait(timeout: .seconds(60)) { !fixture.visibleRows(1).isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        var switches: [Duration] = []
        for round in 0..<10 {
            let index = round.isMultiple(of: 2) ? 0 : 1
            fixture.show(index)
            switches.append(try await fixture.wait { !fixture.visibleRows(index).isEmpty })
            try await Task.sleep(for: .milliseconds(300))
        }
        let warm = ProcessStats.footprintMB - footprint
        let sorted = switches.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted.last ?? .zero
        print("chat-switch \(Self.platform): first frame with content median \(median.formattedMilliseconds),"
              + " worst \(worst.formattedMilliseconds) over \(switches.count); the second warm 2,100-item pane +\(Int(warm)) MB")
        XCTAssertLessThanOrEqual(median, Self.switchBudget, "\(Self.platform): pane switch")
    }
}

#if os(macOS)
extension NSWindow {
    /// Scrolls what is under the window's centre as a trackpad does: a gesture that begins, moves
    /// `steps` times by `delta` points (positive scrolls up, to earlier rows) and ends.
    func scrollChat(by delta: Int32, steps: Int = 6) async {
        guard let content = contentView else { return }
        let inWindow = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
        let onScreen = convertPoint(toScreen: inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let location = CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y)
        func send(_ delta: Int32, phase: CGScrollPhase) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: delta, wheel2: 0, wheel3: 0) else { return }
            event.location = location
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            if let wheel = NSEvent(cgEvent: event) { sendEvent(wheel) }
        }
        send(0, phase: .began)
        for _ in 0..<steps {
            send(delta, phase: .changed)
            try? await Task.sleep(for: .milliseconds(16))
        }
        send(0, phase: .ended)
        try? await Task.sleep(for: .milliseconds(50))
    }
}
#endif
