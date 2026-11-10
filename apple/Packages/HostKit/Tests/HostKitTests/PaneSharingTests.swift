import Foundation
@testable import HostKit
import PaneLayout
import Synchronization
import Testing
import TerminalCore
import GudoCore

/// One pane shown in two windows (docs/APP-ARCHITECTURE.md "Windows"): one stream, a terminal
/// per window, the later window seeded from the earlier one, one size, and acks to the window
/// that typed.
@MainActor
@Suite struct PaneSharingTests {
    private func makeConnection() throws -> (DaemonConnection, () -> FakeClient) {
        let client = Mutex<FakeClient?>(nil)
        let connection = DaemonConnection(hostId: "h", ticket: "t", session: 7) { _, listener in
            let fake = FakeClient(listener: listener)
            client.withLock { $0 = fake }
            return fake
        }
        try connection.connect()
        return (connection, { client.withLock { $0! } })
    }

    /// A terminal fed by a sink, like a window's `Pane`.
    private final class Window: Sendable {
        let terminal = Terminal(cols: 40, rows: 5) { _ in }
        let events = EventSink()

        var handler: @Sendable (PaneEvent) -> Void {
            { [terminal, events] event in
                events.handler(event)
                switch event {
                case .output(let data): data.withUnsafeBytes { terminal.write($0) }
                case .snapshot(let data): try? terminal.restore(snapshot: data)
                case .history(let data, _): _ = try? terminal.appendHistory(data)
                default: break
                }
            }
        }

        var seed: @Sendable () -> [PaneEvent] { { [terminal] in terminal.seedEvents() } }
        var text: String { terminal.plainText() }
    }

    @Test func twoWindowsShareOneSubscription() async throws {
        let (connection, client) = try makeConnection()
        client().send(.connected(epoch: 1, resumed: false))
        let windowA = Window(), windowB = Window()
        let tapA = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tapA.start(events: windowA.handler, seed: windowA.seed)
        client().send(.paneBytes(paneId: 3, seq: 0, data: Data("first line\r\n".utf8)))
        #expect(windowA.text.contains("first line"))

        // The second window starts from the first one's terminal: nothing is asked of the daemon.
        let tapB = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tapB.start(events: windowB.handler, seed: windowB.seed)
        #expect(client().calls.filter { $0 == .subscribe(3) }.count == 1)
        try await eventually("the second window's copy") { windowB.text.contains("first line") }
        #expect(windowB.events.lastConnection == .live)

        // Both follow the stream.
        client().send(.paneBytes(paneId: 3, seq: 12, data: Data("second".utf8)))
        #expect(windowA.text.contains("second"))
        #expect(windowB.text.contains("second"))

        // Closing one window keeps the subscription; closing the last ends it.
        tapA.terminate()
        #expect(!client().calls.contains(.unsubscribe(3)))
        client().send(.paneBytes(paneId: 3, seq: 18, data: Data(" third".utf8)))
        #expect(windowB.text.contains("third"))
        #expect(!windowA.text.contains("third"))
        tapB.terminate()
        #expect(client().calls.last == .unsubscribe(3))
    }

    /// Copying a window's terminal for another (up to megabytes of scrollback) happens off the
    /// caller's thread and never holds up the host's other panes; output that arrives meanwhile
    /// reaches both windows once, after the copy.
    @Test func aSlowCopyStallsNeitherTheCallerNorOtherPanes() async throws {
        let (connection, client) = try makeConnection()
        client().send(.connected(epoch: 1, resumed: false))
        let windowA = Window(), windowB = Window(), other = Window()
        let copying = Atomic(false), release = DispatchSemaphore(value: 0)
        let slowSeed: @Sendable () -> [PaneEvent] = { [seed = windowA.seed] in
            copying.store(true, ordering: .releasing)
            _ = release.wait(timeout: .now() + 5)
            return seed()
        }
        let tapA = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tapA.start(events: windowA.handler, seed: slowSeed)
        let otherTap = try #require(try connection.makeBackend(for: PaneId(4)) as? DaemonPaneBackend)
        otherTap.start(events: other.handler, seed: other.seed)
        client().send(.paneBytes(paneId: 3, seq: 0, data: Data("first line\r\n".utf8)))

        let tapB = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let started = ContinuousClock.now
        tapB.start(events: windowB.handler, seed: windowB.seed)
        #expect(ContinuousClock.now - started < .milliseconds(500), "the caller does not wait for the copy")
        try await eventually("the copy") { copying.load(ordering: .acquiring) }

        // While the copy runs, other panes' output arrives at once; this pane's waits for it.
        client().send(.paneBytes(paneId: 4, seq: 0, data: Data("other pane".utf8)))
        #expect(other.text.contains("other pane"))
        client().send(.paneBytes(paneId: 3, seq: 12, data: Data("during copy".utf8)))
        release.signal()
        try await eventually("both windows") { windowA.text.contains("during copy") && windowB.text.contains("during copy") }
        #expect(windowB.text.contains("first line"))
        #expect(windowB.text.components(separatedBy: "during copy").count == 2, "applied once")
        #expect(windowB.events.lastConnection == .live)
    }

    @Test(arguments: [false, true])
    func cachingAHiddenViewportWaitsForActualInputBeforeResizing(predicted: Bool) throws {
        let (connection, client) = try makeConnection()
        let tap = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tap.start(events: { _ in }, seed: nil)
        client().clear()
        tap.cacheSize(cols: 60, rows: 20, cellWidth: 10, cellHeight: 20)
        #expect(client().calls.isEmpty)
        #expect(!tap.drivesLocalSize)
        Array("typed".utf8).withUnsafeBytes {
            if predicted { tap.writeInput($0, inputSeq: 1) } else { tap.write($0) }
        }
        #expect(client().calls == [.resize(3, PaneSize(cols: 60, rows: 20, widthPx: 600, heightPx: 400)), .input(3, Data("typed".utf8))])
        #expect(tap.drivesLocalSize)
        client().clear()
        Array("next".utf8).withUnsafeBytes { tap.write($0) }
        #expect(client().calls == [.input(3, Data("next".utf8))])
    }

    @Test func aDrivingTapsDeferredViewportIgnoresReportsButAppliesBeforeItsNextPaste() throws {
        let (connection, client) = try makeConnection()
        let tap = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tap.start(events: { _ in }, seed: nil)
        tap.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        client().clear()
        tap.cacheSize(cols: 60, rows: 20, cellWidth: 10, cellHeight: 20)
        Array("\u{1b}[I".utf8).withUnsafeBytes { tap.write($0) }
        #expect(client().calls == [.input(3, Data("\u{1b}[I".utf8))])
        client().clear()
        Array("report".utf8).withUnsafeBytes { tap.writeGenerated($0) }
        #expect(client().calls == [.generatedInput(3, Data("report".utf8))])
        client().clear()
        tap.paste("pasted")
        #expect(client().calls == [.resize(3, PaneSize(cols: 60, rows: 20, widthPx: 600, heightPx: 400)), .paste(3, "pasted")])
    }

    @Test func aHiddenCachedViewportIsNotAnAutomaticSizingHandoverCandidate() throws {
        let (connection, client) = try makeConnection()
        let active = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let hidden = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        active.start(events: { _ in }, seed: nil)
        hidden.start(events: { _ in }, seed: nil)
        active.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        hidden.cacheSize(cols: 60, rows: 20, cellWidth: 10, cellHeight: 20)
        client().clear()
        active.terminate()
        #expect(client().calls.isEmpty)
        hidden.claimSize()
        #expect(client().calls == [.resize(3, PaneSize(cols: 60, rows: 20, widthPx: 600, heightPx: 400)), .claimSize(3)])
    }

    @Test func viewportLayoutPreservesDeferralUntilInput() throws {
        let (connection, client) = try makeConnection()
        let tap = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tap.start(events: { _ in }, seed: nil)
        client().clear()
        tap.deferSize()
        #expect(!tap.layoutViewport(cols: 60, rows: 20, cellWidth: 10, cellHeight: 20))
        #expect(tap.isSizeDeferred)
        #expect(client().calls.isEmpty)
        Array("typed".utf8).withUnsafeBytes { tap.write($0) }
        #expect(!tap.isSizeDeferred)
        #expect(client().calls == [.resize(3, PaneSize(cols: 60, rows: 20, widthPx: 600, heightPx: 400)), .input(3, Data("typed".utf8))])
        client().clear()
        #expect(tap.layoutViewport(cols: 70, rows: 20, cellWidth: 10, cellHeight: 20))
        #expect(client().calls == [.resize(3, PaneSize(cols: 70, rows: 20, widthPx: 700, heightPx: 400))])
    }

    @Test func deferringBeforeAHiddenLayoutDoesNotClaimOrResize() throws {
        let (connection, client) = try makeConnection()
        let tap = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tap.start(events: { _ in }, seed: nil)
        tap.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        client().clear()
        tap.deferSize()
        #expect(tap.isSizeDeferred)
        #expect(client().calls.isEmpty)
        tap.claimSize()
        #expect(!tap.isSizeDeferred)
        #expect(client().calls == [.resize(3, PaneSize(cols: 120, rows: 40, widthPx: 1200, heightPx: 800)), .claimSize(3)])
    }

    @Test func cancellingSizeDeferralDoesNotClaimOrProposeGeometry() throws {
        let (connection, client) = try makeConnection()
        let tap = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tap.start(events: { _ in }, seed: nil)
        client().clear()
        tap.deferSize()
        #expect(!tap.layoutViewport(cols: 60, rows: 20, cellWidth: 10, cellHeight: 20))
        tap.cancelSizeDeferral()
        #expect(!tap.isSizeDeferred)
        #expect(client().calls.isEmpty)
        #expect(tap.layoutViewport(cols: 70, rows: 20, cellWidth: 10, cellHeight: 20))
        #expect(client().calls == [.resize(3, PaneSize(cols: 70, rows: 20, widthPx: 700, heightPx: 400))])
    }

    @Test(arguments: [false, true])
    func viewportPixelMetricsClampWithoutOverflow(deferred: Bool) throws {
        let (connection, client) = try makeConnection()
        let tap = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tap.start(events: { _ in }, seed: nil)
        client().clear()
        if deferred {
            tap.cacheSize(cols: 2, rows: 2, cellWidth: .max, cellHeight: .max)
            #expect(client().calls.isEmpty)
            tap.claimSize()
        } else {
            tap.resize(cols: 2, rows: 2, cellWidth: .max, cellHeight: .max)
        }
        #expect(client().calls.first == .resize(3, PaneSize(cols: 2, rows: 2, widthPx: .max, heightPx: .max)))
    }

    @Test func emptyCachedViewportsDoNotReplaceTheLastValidCandidate() throws {
        let (connection, client) = try makeConnection()
        let tap = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tap.start(events: { _ in }, seed: nil)
        client().clear()
        tap.cacheSize(cols: 60, rows: 20, cellWidth: 10, cellHeight: 20)
        tap.cacheSize(cols: 0, rows: 20, cellWidth: 10, cellHeight: 20)
        tap.cacheSize(cols: 60, rows: 0, cellWidth: 10, cellHeight: 20)
        #expect(client().calls.isEmpty)
        tap.claimSize()
        #expect(client().calls == [.resize(3, PaneSize(cols: 60, rows: 20, widthPx: 600, heightPx: 400)), .claimSize(3)])
    }

    @Test func theWindowThatTypesDrivesTheSize() async throws {
        let (connection, client) = try makeConnection()
        let tapA = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let tapB = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tapA.start(events: { _ in }, seed: nil)
        tapB.start(events: { _ in }, seed: nil)
        let big = PaneSize(cols: 120, rows: 40, widthPx: 1200, heightPx: 800)
        let small = PaneSize(cols: 60, rows: 20, widthPx: 600, heightPx: 400)
        tapA.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        #expect(client().calls.last == .resize(3, big))
        client().clear()
        // Another window's layout does not resize the pane under the one that drives it…
        tapB.resize(cols: 60, rows: 20, cellWidth: 10, cellHeight: 20)
        #expect(client().calls.isEmpty)
        // …until it types (its size goes first) or takes focus.
        Array("x".utf8).withUnsafeBytes { tapB.write($0) }
        #expect(client().calls == [.resize(3, small), .input(3, Data("x".utf8))])
        client().clear()
        tapA.claimSize()
        #expect(client().calls == [.resize(3, big), .claimSize(3)])
        // The driving window closes: the other one's size takes over.
        client().clear()
        tapA.terminate()
        #expect(client().calls == [.resize(3, small)])
    }

    @Test(arguments: [false, true])
    func focusReportsDoNotTakeTheOtherWindowsSize(usesPrediction: Bool) async throws {
        let (connection, client) = try makeConnection()
        let desktop = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let phone = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        desktop.start(events: { _ in }, seed: nil)
        phone.start(events: { _ in }, seed: nil)
        desktop.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        phone.resize(cols: 45, rows: 20, cellWidth: 10, cellHeight: 20)
        let reports: [[UInt8]] = [[0x1b, 0x5b, 0x49], [0x1b, 0x5b, 0x4f], [0x9b, 0x49], [0x9b, 0x4f]]
        for bytes in reports {
            client().clear()
            bytes.withUnsafeBytes {
                if usesPrediction { phone.writeInput($0, inputSeq: 7) }
                else { phone.write($0) }
            }
            #expect(client().calls == [.input(3, Data(bytes))])
        }
        client().clear()
        desktop.resize(cols: 121, rows: 40, cellWidth: 10, cellHeight: 20)
        #expect(client().calls == [.resize(3, PaneSize(cols: 121, rows: 40, widthPx: 1210, heightPx: 800))])
    }

    @Test func generatedInputDoesNotClaimOrChangeTheDrivingWindow() async throws {
        let (connection, client) = try makeConnection()
        let desktop = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let phone = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        desktop.start(events: { _ in }, seed: nil)
        phone.start(events: { _ in }, seed: nil)
        desktop.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        phone.resize(cols: 45, rows: 20, cellWidth: 10, cellHeight: 20)
        client().clear()
        let report = Array("\u{1b}[<0;1;1M".utf8)
        report.withUnsafeBytes { phone.writeGenerated($0) }
        #expect(client().calls == [.generatedInput(3, Data(report))])
        client().clear()
        desktop.resize(cols: 121, rows: 40, cellWidth: 10, cellHeight: 20)
        #expect(client().calls == [.resize(3, PaneSize(cols: 121, rows: 40, widthPx: 1210, heightPx: 800))])
    }

    @Test(arguments: [false, true])
    func heldReportsDoNotTakeSizeWhenTheSavedScreenBecomesLive(tagged: Bool) async throws {
        let (connection, client) = try makeConnection()
        let desktop = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let phone = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        desktop.start(events: { _ in }, seed: nil)
        phone.start(events: { _ in }, seed: nil)
        desktop.resize(cols: 120, rows: 40, cellWidth: 10, cellHeight: 20)
        phone.resize(cols: 45, rows: 20, cellWidth: 10, cellHeight: 20)
        phone.holdInputUntilLive(screen: { "saved" }, onChange: { _ in })
        client().clear()
        let report = Array("\u{1b}[I".utf8)
        report.withUnsafeBytes { if tagged { phone.writeGenerated($0) } else { phone.write($0) } }
        #expect(client().calls.isEmpty)
        client().send(.paneSnapshot(paneId: 3, seq: 0, data: Data()))
        let expected: FakeClient.Call = tagged ? .generatedInput(3, Data(report)) : .input(3, Data(report))
        try await eventually("held report delivered") { client().calls.contains(expected) }
        #expect(client().calls == [expected])
        client().clear()
        desktop.resize(cols: 121, rows: 40, cellWidth: 10, cellHeight: 20)
        #expect(client().calls == [.resize(3, PaneSize(cols: 121, rows: 40, widthPx: 1210, heightPx: 800))])
    }

    @Test func generatedReportsKeepFollowingKeyAcknowledgementsAligned() async throws {
        let (connection, client) = try makeConnection()
        client().send(.connected(epoch: 1, resumed: false))
        let backend = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        backend.start(events: { _ in }, seed: nil)
        let predictions = PredictionSink()
        backend.startPredictionFeed(predictions.handler)
        Array("\u{1b}[I".utf8).withUnsafeBytes { backend.writeGenerated($0) }
        Array("x".utf8).withUnsafeBytes { backend.writeInput($0, inputSeq: 7) }
        client().send(.inputAck(paneId: 3, inputSeq: 1, atSeq: 0))
        client().send(.paneBytes(paneId: 3, seq: 0, data: Data("g".utf8)))
        #expect(!predictions.all.contains(.acknowledged(upTo: 7, hint: nil)))
        client().send(.inputAck(paneId: 3, inputSeq: 2, atSeq: 1))
        client().send(.paneBytes(paneId: 3, seq: 1, data: Data("x".utf8)))
        #expect(predictions.all.contains(.acknowledged(upTo: 7, hint: nil)))
    }

    @Test func acksGoToTheWindowThatTyped() async throws {
        let (connection, client) = try makeConnection()
        client().send(.connected(epoch: 1, resumed: false))
        let tapA = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let tapB = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tapA.start(events: { _ in }, seed: nil)
        tapB.start(events: { _ in }, seed: nil)
        let predictionsA = PredictionSink(), predictionsB = PredictionSink()
        tapA.startPredictionFeed(predictionsA.handler)
        tapB.startPredictionFeed(predictionsB.handler)
        Array("l".utf8).withUnsafeBytes { tapB.writeInput($0, inputSeq: 7) }
        client().send(.inputAck(paneId: 3, inputSeq: 1, atSeq: 10))
        client().send(.paneBytes(paneId: 3, seq: 10, data: Data("l".utf8)))
        #expect(predictionsB.all.contains(.acknowledged(upTo: 7, hint: nil)))
        #expect(!predictionsA.all.contains { if case .acknowledged = $0 { true } else { false } })
        // Hints are the pane's: every window hears them.
        client().send(.echoHint(hint: GudoCore.EchoHint(paneId: 3, echo: true, icanon: false, altScreen: false, atPrompt: true, atSeq: 11, prediction: .allow)))
        let hint = PredictionUpdate.hint(TerminalCore.EchoHint(echo: true, canonical: false, atPrompt: true, altScreen: false))
        #expect(predictionsA.all.last == hint)
        #expect(predictionsB.all.last == hint)
    }

    @Test func drawingOffsetsArePerWindow() async throws {
        let (connection, client) = try makeConnection()
        let tapA = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let tapB = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        tapA.start(events: { _ in }, seed: nil)
        tapB.start(events: { _ in }, seed: nil)
        let seenA = Mutex<[UInt64]>([]), seenB = Mutex<[UInt64]>([])
        tapA.onOutputApplied { seq, _ in seenA.withLock { $0.append(seq) } }
        tapB.onOutputApplied { seq, _ in seenB.withLock { $0.append(seq) } }
        client().send(.paneBytes(paneId: 3, seq: 0, data: Data("abc".utf8)))
        #expect(seenA.withLock { $0 } == [3])
        #expect(seenB.withLock { $0 } == [3])
    }

    @Test func inactiveWindowReportsBeforeVisibilityAndDoesNotChangeIt() throws {
        let (connection, client) = try makeConnection()
        let window = NSObject()
        client().clear()
        connection.setWindowView(window, focused: PaneId(1), visible: [PaneId(1)], activity: .inactive)
        #expect(client().calls == [.activity(1, .inactive), .setView(1, [1])])
        client().clear()
        connection.setWindowView(window, focused: PaneId(1), visible: [PaneId(1)], activity: .active)
        #expect(client().calls == [.activity(1, .active)])
    }

    @Test func anInactiveWindowsReportDoesNotTakeTheActiveWindowsFocus() throws {
        let (connection, client) = try makeConnection()
        let windowA = NSObject(), windowB = NSObject()
        connection.setWindowView(windowA, focused: PaneId(1), visible: [PaneId(1)])
        connection.setWindowView(windowB, focused: PaneId(3), visible: [PaneId(3)], activity: .inactive)
        #expect(client().calls.last == .setView(1, [1, 3]))
    }

    @Test func activityIsSeededBeforeTheClientConnects() throws {
        let recorded = Mutex<FakeClient?>(nil)
        let connection = DaemonConnection(hostId: "h", ticket: "t") { _, listener in
            let client = FakeClient(listener: listener)
            recorded.withLock { $0 = client }
            return client
        }
        let window = NSObject()
        connection.setWindowView(window, focused: PaneId(1), visible: [PaneId(1)], activity: .inactive)
        try connection.connect()
        let client = try #require(recorded.withLock { $0 })
        #expect(client.calls.prefix(2) == [.activity(1, .inactive), .setView(1, [1])])
    }

    @Test func overlappingWindowsKeepActivityUntilTheLastActiveOneLeaves() throws {
        let (connection, client) = try makeConnection()
        let windowA = NSObject(), windowB = NSObject()
        connection.setWindowView(windowA, focused: PaneId(1), visible: [PaneId(1)])
        connection.setWindowView(windowB, focused: PaneId(1), visible: [PaneId(1)])
        client().clear()
        connection.setWindowView(windowA, focused: PaneId(1), visible: [PaneId(1)], activity: .inactive)
        #expect(client().calls.isEmpty)
        connection.setWindowView(windowB, focused: nil, visible: [])
        #expect(client().calls == [.activity(1, .inactive)])
        client().clear()
        connection.setWindowView(windowA, focused: nil, visible: [])
        #expect(client().calls == [.setView(nil, [])])
    }

    @Test func sameGridLocalHandoffsNotifyBothWindowsAndClosingTheDriverRestoresTheOther() throws {
        let (connection, _) = try makeConnection()
        let a = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let b = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        let eventsA = EventSink(), eventsB = EventSink()
        a.start(events: eventsA.handler)
        b.start(events: eventsB.handler)
        a.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        b.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        b.claimSize()
        #expect(!a.drivesLocalSize && b.drivesLocalSize)
        #expect(eventsA.all.filter { $0 == .sizingChanged }.count == 1)
        #expect(eventsB.all.filter { $0 == .sizingChanged }.count == 1)
        b.claimSize()
        #expect(eventsA.all.filter { $0 == .sizingChanged }.count == 1)
        b.detach()
        #expect(a.drivesLocalSize)
        #expect(eventsA.all.filter { $0 == .sizingChanged }.count == 2)
    }

    @Test func takingSizeClaimsBeforeChangingPolicyAndRespectsTheInputGate() throws {
        let (connection, client) = try makeConnection()
        let backend = try #require(try connection.makeBackend(for: PaneId(3)) as? DaemonPaneBackend)
        backend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        client().clear()
        (backend as any SharedPaneTap).useSize()
        #expect(client().calls == [.claimSize(3), .sizePolicy(3, .lastActive)])
        backend.router.setGate(MultiplayerSession.InputGate(all: true, panes: []))
        client().clear()
        (backend as any SharedPaneTap).useSize()
        #expect(client().calls.isEmpty)
    }

    @Test func explicitClaimsReachTheDaemonEvenWhenTheLocalTapAlreadyDrives() throws {
        let (connection, client) = try makeConnection()
        let backend = try connection.makeBackend(for: PaneId(3))
        backend.resize(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
        client().clear()
        (backend as? any SharedPaneTap)?.claimSize()
        (backend as? any SharedPaneTap)?.claimSize()
        #expect(client().calls == [.claimSize(3), .claimSize(3)])
    }

    @Test func theDaemonHearsEveryWindowsPanes() async throws {
        let (connection, client) = try makeConnection()
        client().send(.connected(epoch: 1, resumed: false))
        client().send(.attached(sessionId: 7, via: .requested, missing: nil))
        client().send(.layout(layout: sampleLayout()))
        try await eventually("ready") { connection.isReady }
        let windowA = NSObject(), windowB = NSObject()
        connection.setWindowView(windowA, focused: PaneId(1), visible: [PaneId(1)])
        connection.setWindowView(windowB, focused: PaneId(3), visible: [PaneId(2), PaneId(3)])
        #expect(client().calls.last == .setView(3, [1, 2, 3]))
        connection.setWindowView(windowB, focused: nil, visible: [])
        #expect(client().calls.last == .setView(1, [1]))
        // The last window leaves too (the app went to the background): nothing is on screen,
        // not the layout's active tab, so the daemon notifies about it.
        connection.setWindowView(windowA, focused: nil, visible: [])
        #expect(client().calls.last == .setView(nil, []))
    }
}

/// Local PTYs, plain-SSH channels and the echo stand-in: one backend, a tap per window.
@Suite struct SharedPaneBackendTests {
    /// A byte-stream backend that records what reaches it.
    private final class Recorder: PaneBackend, @unchecked Sendable {
        let lock = Mutex<(sink: (@Sendable (PaneEvent) -> Void)?, starts: Int, writes: [String], sizes: [UInt16], terminated: Bool)>((nil, 0, [], [], false))

        func start(events: @escaping @Sendable (PaneEvent) -> Void) {
            lock.withLock {
                $0.sink = events
                $0.starts += 1
            }
        }
        func emit(_ text: String) { lock.withLock { $0.sink }?(.output(Data(text.utf8))) }
        func write(_ bytes: UnsafeRawBufferPointer) { lock.withLock { $0.writes.append(String(decoding: bytes, as: UTF8.self)) } }
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) { lock.withLock { $0.sizes.append(cols) } }
        func terminate() { lock.withLock { $0.terminated = true } }
    }

    private final class Window: Sendable {
        let terminal = Terminal(cols: 40, rows: 5) { _ in }
        var handler: @Sendable (PaneEvent) -> Void {
            { [terminal] event in
                switch event {
                case .output(let data): data.withUnsafeBytes { terminal.write($0) }
                case .snapshot(let data): try? terminal.restore(snapshot: data)
                case .history(let data, _): _ = try? terminal.appendHistory(data)
                default: break
                }
            }
        }
        var seed: @Sendable () -> [PaneEvent] { { [terminal] in terminal.seedEvents() } }
    }

    @Test func oneProcessManyWindows() {
        let recorder = Recorder()
        let shared = SharedPaneBackend(recorder)
        let windowA = Window(), windowB = Window()
        let tapA = shared.makeTap()
        tapA.start(events: windowA.handler, seed: windowA.seed)
        recorder.emit("hello\r\n")
        let tapB = shared.makeTap()
        tapB.start(events: windowB.handler, seed: windowB.seed)
        #expect(recorder.lock.withLock { $0.starts } == 1)
        #expect(windowB.terminal.plainText().contains("hello"))
        recorder.emit("again")
        #expect(windowA.terminal.plainText().contains("again"))
        #expect(windowB.terminal.plainText().contains("again"))

        Array("ls".utf8).withUnsafeBytes { tapB.write($0) }
        #expect(recorder.lock.withLock { $0.writes } == ["ls"])

        tapA.terminate()
        #expect(!recorder.lock.withLock { $0.terminated })
        tapB.terminate()
        #expect(recorder.lock.withLock { $0.terminated })
        #expect(shared.isTerminated)
    }

    @Test func sizeFollowsTheWindowThatTyped() {
        let recorder = Recorder()
        let shared = SharedPaneBackend(recorder)
        let tapA = shared.makeTap(), tapB = shared.makeTap()
        tapA.start(events: { _ in }, seed: nil)
        tapB.start(events: { _ in }, seed: nil)
        tapA.resize(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        tapB.resize(cols: 50, rows: 30, cellWidth: 8, cellHeight: 16)
        #expect(recorder.lock.withLock { $0.sizes } == [100])
        Array("\u{1b}[I".utf8).withUnsafeBytes { tapB.writeGenerated($0) }
        #expect(recorder.lock.withLock { $0.sizes } == [100])
        #expect(recorder.lock.withLock { $0.writes } == ["\u{1b}[I"])
        Array("x".utf8).withUnsafeBytes { tapB.write($0) }
        #expect(recorder.lock.withLock { $0.sizes } == [100, 50])
        tapA.claimSize()
        #expect(recorder.lock.withLock { $0.sizes } == [100, 50, 100])
    }

    @Test func closingTheLastWindowParksTheStream() {
        let recorder = Recorder()
        let shared = SharedPaneBackend(recorder)
        let windowA = Window()
        let tapA = shared.makeTap()
        tapA.start(events: windowA.handler, seed: windowA.seed)
        recorder.emit("before close\r\n")
        tapA.detach()
        #expect(!recorder.lock.withLock { $0.terminated })
        #expect(shared.isParked)
        recorder.emit("while closed\r\n")

        let windowB = Window()
        let tapB = shared.makeTap()
        tapB.start(events: windowB.handler, seed: windowB.seed)
        #expect(windowB.terminal.plainText().contains("before close"))
        #expect(windowB.terminal.plainText().contains("while closed"))
        #expect(!shared.isParked)
        #expect(recorder.lock.withLock { $0.starts } == 1)
    }
}
