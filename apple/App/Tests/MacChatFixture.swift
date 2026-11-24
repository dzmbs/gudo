#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import Observation
import os
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// A real Chat pane on the Mac, fed by a fixture timeline, in a window far off every display.
@MainActor
final class MacChatFixture {
    @MainActor @Observable final class Agent {
        var working: Bool
        init(working: Bool) { self.working = working }
    }

    final class Backend: DeferredPaneSizing, SharedPaneTap, @unchecked Sendable {
        struct State {
            var isDeferred = false
            var claims = 0
            var input = Data()
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        var sizeFollowsStream: Bool { true }
        var isSizeDeferred: Bool { state.withLock { $0.isDeferred } }
        func deferSize() { state.withLock { $0.isDeferred = true } }
        func cancelSizeDeferral() { state.withLock { $0.isDeferred = false } }
        func layoutViewport(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) -> Bool {
            state.withLock { !$0.isDeferred }
        }
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {}
        func start(events: @escaping @Sendable (PaneEvent) -> Void, seed: (@Sendable () -> [PaneEvent])?) {}
        func write(_ bytes: UnsafeRawBufferPointer) {
            let input = Data(bytes)
            state.withLock { $0.isDeferred = false; $0.input.append(input) }
        }
        func writeGenerated(_ bytes: UnsafeRawBufferPointer) {}
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {}
        func claimSize() { state.withLock { $0.isDeferred = false; $0.claims += 1 } }
        func useSize() { state.withLock { $0.isDeferred = false; $0.claims += 1 } }
        func terminate() {}
    }

    private struct Harness: View {
        let pane: Pane
        let state: PaneChatState
        let hub: DaemonWorkspace
        @Bindable var agent: Agent

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Review the change").font(DS.Font.rowTitleEmphasis)
                    Spacer()
                    PaneChatButton(pane: pane, state: state).labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .padding(.horizontal, DS.Space.l).frame(height: DS.Size.touchTarget)
                PaneChatView(pane: pane, state: state, hub: hub, permitsSending: true, working: agent.working) { _ in
                    Text("Terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(DS.Palette.text)
            .chromeBackground(DS.Palette.base)
        }
    }

    let pane: Pane
    let state: PaneChatState
    let client: TimelineFixtureClient
    let events: WorkspaceEventHub
    let hub: DaemonWorkspace
    let agent: Agent
    let backend: Backend
    let window: NSWindow
    let preferences: UserDefaults
    private let suite: String

    init(snapshot: String, working: Bool = false, presentation: PanePresentation = .chat,
         size: CGSize = CGSize(width: 900, height: 760), files: [String: Data] = [:],
         makeWindow: ((AnyView, CGSize) -> NSWindow)? = nil) throws {
        suite = "mac-chat-" + UUID().uuidString
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        backend = Backend()
        pane = try Pane(id: PaneId(7), backend: backend, appearance: .fromPreferences(), onExit: {})
        state = PaneChatState(member: HostPane(hostId: "fixture", pane: pane.id), defaultPresentation: presentation,
                              agent: .claude, inputPresentation: pane.inputPresentation,
                              preferences: preferences, pool: ChatModelPool(capacity: 1), dictation: .init())
        let pane = pane
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
        let client = TimelineFixtureClient(snapshot: snapshot, nativeMessageReceipts: true)
        client.state.withLock { state in
            for (path, data) in files { state.files[path] = data }
        }
        self.client = client
        events = WorkspaceEventHub()
        hub = DaemonWorkspace(hostId: "fixture", events: events, resolve: { client })
        agent = Agent(working: working)
        let root = AnyView(ThemedRoot { [state, hub, agent] in Harness(pane: pane, state: state, hub: hub, agent: agent) })
        if let makeWindow {
            window = makeWindow(root, size)
        } else {
            let frame = NSRect(x: -30000, y: -30000, width: size.width, height: size.height)
            window = NSWindow(contentRect: frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: root)
            window.setFrame(frame, display: false)
            window.orderFrontRegardless()
        }
    }

    /// A Chat view with this fixture's inputs, for its actions.
    func view() -> PaneChatView<Color> {
        PaneChatView(pane: pane, state: state, hub: hub, permitsSending: true, working: agent.working) { _ in Color.clear }
    }

    var model: TimelineModel? { state.model }
    var controller: ChatTranscriptController? { state.controller }
    var visibleRows: [ChatRowID] { state.controller?.visibleRows ?? [] }

    func close() {
        state.deactivate()
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
        preferences.removePersistentDomain(forName: suite)
    }

    /// Scrolls the transcript as a trackpad does: a gesture that begins, moves `steps` times by
    /// `delta` points (positive scrolls up, to earlier rows) and ends.
    func scrollWheel(by delta: Int32, steps: Int = 6) async {
        guard let content = window.contentView else { return }
        let inWindow = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let location = CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y)
        func send(_ delta: Int32, phase: CGScrollPhase) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: delta, wheel2: 0, wheel3: 0) else { return }
            event.location = location
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            if let wheel = NSEvent(cgEvent: event) { window.sendEvent(wheel) }
        }
        send(0, phase: .began)
        for _ in 0..<steps {
            send(delta, phase: .changed)
            try? await Task.sleep(for: .milliseconds(16))
        }
        send(0, phase: .ended)
        try? await Task.sleep(for: .milliseconds(50))
    }

    func wait(timeout: Duration = .seconds(20), file: StaticString = #filePath, line: UInt = #line,
              _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Chat did not reach its expected state", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
#endif
