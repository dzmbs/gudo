import Foundation
import HostKit
import PaneLayout
import Synchronization
import XCTest
@testable import App

/// The window layer (docs/APP-ARCHITECTURE.md "Windows"): width buckets, Handoff payloads, and
/// two windows' workspaces on one host.
@MainActor
final class WindowsTests: XCTestCase {
    // MARK: Width buckets

    func testWidthsPickTheLayoutNotTheDevice() {
        // iPhone portrait, Slide Over, a third of an iPad, an 11" iPad half: compact.
        for width in [320.0, 375, 393, 440, 507, 590] {
            XCTAssertEqual(WidthBucket.of(width: width, current: nil), .compact, "\(width) pt")
        }
        // iPhone landscape, a foldable's inner screen, iPad mini, a 13" half, full iPads, Macs.
        for width in [600.0, 678, 744, 768, 820, 852, 932, 1024, 1366] {
            XCTAssertEqual(WidthBucket.of(width: width, current: nil), .regular, "\(width) pt")
        }
    }

    func testCrossingTheBoundarySwitchesOnceWithHysteresis() {
        // A live resize from wide to narrow and back: one switch each way, never a flip-flop at
        // the boundary.
        var bucket: WidthBucket? = nil
        var switches: [WidthBucket] = []
        let drag = Array(stride(from: 900.0, through: 400, by: -3)) + Array(stride(from: 400.0, through: 900, by: 3))
        for width in drag {
            let next = WidthBucket.of(width: width, current: bucket)
            if next != bucket { switches.append(next) }
            bucket = next
        }
        XCTAssertEqual(switches, [.regular, .compact, .regular])
        // Hovering around the boundary changes nothing.
        bucket = .regular
        for width in [601.0, 598, 593, 599, 605, 590] {
            bucket = WidthBucket.of(width: width, current: bucket)
            XCTAssertEqual(bucket, .regular, "\(width) pt")
        }
        bucket = .compact
        for width in [599.0, 605, 610, 600, 611] {
            bucket = WidthBucket.of(width: width, current: bucket)
            XCTAssertEqual(bucket, .compact, "\(width) pt")
        }
        XCTAssertEqual(WidthBucket.of(width: 587, current: .regular), .compact)
        XCTAssertEqual(WidthBucket.of(width: 612, current: .compact), .regular)
    }

    /// Two Columns turns on by itself only on a phone window regular both ways: a foldable's
    /// open inner screen. Phones in portrait or landscape, iPads and Macs never.
    func testTwoColumnsComeOnByThemselvesOnlyOnAnOpenFoldable() {
        // Open foldables' inner screens (portrait and landscape).
        XCTAssertTrue(WidthBucket.isTwoSegment(width: 678, height: 870, isPhone: true))
        XCTAssertTrue(WidthBucket.isTwoSegment(width: 870, height: 678, isPhone: true))
        // iPhones: portrait is compact, landscape is short.
        XCTAssertFalse(WidthBucket.isTwoSegment(width: 440, height: 956, isPhone: true))
        XCTAssertFalse(WidthBucket.isTwoSegment(width: 956, height: 440, isPhone: true))
        // A wide iPad or Mac window: the user's choice (View ▸ Two Columns), never automatic.
        XCTAssertFalse(WidthBucket.isTwoSegment(width: 1366, height: 1024, isPhone: false))
    }

    // MARK: Handoff

    private func payload(kind: HandoffPayload.Kind = .daemon, hostId: String? = "A", daemonId: String? = "d1", ssh: String? = nil, origin: String = "other") -> HandoffPayload {
        HandoffPayload(kind: kind, hostId: hostId, hostName: "studio", daemonId: daemonId, ssh: ssh, tab: 4, pane: 9, origin: origin, device: "This iPad")
    }

    func testPayloadSurvivesTheActivity() throws {
        let original = payload(ssh: "me@studio")
        let restored = try XCTUnwrap(HandoffPayload(userInfo: original.userInfo()))
        XCTAssertEqual(restored, original)
        XCTAssertNil(HandoffPayload(userInfo: ["payload": Data("nope".utf8)]))
        XCTAssertNil(HandoffPayload(userInfo: nil))
    }

    // MARK: Handoff of drawings

    func testADrawingSurvivesTheActivityAndOldPayloadsHaveNone() throws {
        var original = payload()
        original.drawing = HandoffPayload.Drawing(artifact: 12, placement: 30, canvas: false)
        let restored = try XCTUnwrap(HandoffPayload(userInfo: original.userInfo()))
        XCTAssertEqual(restored.drawing, HandoffPayload.Drawing(artifact: 12, placement: 30, canvas: false))
        // A payload from a build before drawing Handoff still continues (no drawing).
        let old = #"{"kind":"daemon","hostId":"A","hostName":"studio","daemonId":"d1","tab":4,"pane":9,"origin":"o","device":"This Mac"}"#
        let decoded = try JSONDecoder().decode(HandoffPayload.self, from: Data(old.utf8))
        XCTAssertNil(decoded.drawing)
        // The drawing does not change where the activity continues.
        let records = [HostRecord(id: "B", name: "studio", kind: .daemon, daemonId: "d1")]
        XCTAssertEqual(original.resolve(records: records, installation: "me"), .host(id: "B", tab: TabId(4), pane: PaneId(9)))
    }

    func testDrawModeInTheTabWinsOverTheFocusedCanvas() {
        let draw = HandoffPayload.Drawing(artifact: 5, placement: nil, canvas: false)
        let canvas = HandoffPayload.Drawing(artifact: 7, canvas: true)
        let tab = [PaneId(1), PaneId(2), PaneId(3)]
        // Draw mode on an unfocused pane of the tab: the activity names that pane.
        let drawing = HandoffPayload.openDrawing(focus: [PaneId(2): draw, PaneId(3): canvas], tabPanes: tab, focused: PaneId(3))
        XCTAssertEqual(drawing?.pane, PaneId(2))
        XCTAssertEqual(drawing?.drawing, draw)
        // Only the focused canvas pane counts.
        XCTAssertEqual(HandoffPayload.openDrawing(focus: [PaneId(3): canvas], tabPanes: tab, focused: PaneId(3))?.drawing, canvas)
        XCTAssertNil(HandoffPayload.openDrawing(focus: [PaneId(3): canvas], tabPanes: tab, focused: PaneId(1)))
        // Draw mode in another tab is not this window's activity.
        XCTAssertNil(HandoffPayload.openDrawing(focus: [PaneId(9): draw], tabPanes: tab, focused: PaneId(1)))
        XCTAssertNil(HandoffPayload.openDrawing(focus: [:], tabPanes: tab, focused: PaneId(1)))
    }

    func testAnotherDeviceContinuesOnItsOwnRecordOfTheSameDaemon() {
        let records = [
            HostRecord(id: "B", name: "studio here", kind: .daemon, daemonId: "d1"),
            HostRecord(id: "C", name: "other", kind: .daemon, daemonId: "d2"),
        ]
        XCTAssertEqual(payload().resolve(records: records, installation: "me"), .host(id: "B", tab: TabId(4), pane: PaneId(9)))
    }

    func testSSHHostsMatchByAddressAndOpenWithoutTheOtherDevicesTabs() {
        let records = [HostRecord(id: "S", name: "box", kind: .ssh, ssh: SSHEndpoint(user: "me", host: "box", identity: .agent))]
        let ssh = payload(kind: .ssh, daemonId: nil, ssh: "me@box")
        XCTAssertEqual(ssh.resolve(records: records, installation: "me"), .host(id: "S", tab: nil, pane: nil))
    }

    func testAnUnpairedHostIsSaidSo() {
        XCTAssertEqual(payload().resolve(records: [], installation: "me"), .notPaired)
        XCTAssertEqual(payload(kind: .ssh, daemonId: nil, ssh: "me@box").resolve(records: [], installation: "me"), .notPaired)
    }

    func testThisDevicesOwnShellOnlyContinuesHere() {
        let local = payload(kind: .local, hostId: nil, daemonId: nil)
        XCTAssertEqual(local.resolve(records: [], installation: "me"), .elsewhere)
        XCTAssertFalse(local.isContinuable)
        let dragged = payload(kind: .local, hostId: nil, daemonId: nil, origin: "me")
        XCTAssertEqual(dragged.resolve(records: [], installation: "me"), .local(tab: TabId(4), pane: PaneId(9)))
    }

    func testATabDraggedOutUsesThisDevicesHostId() {
        let records = [HostRecord(id: "A", name: "studio", kind: .daemon, daemonId: "d1")]
        XCTAssertEqual(payload(origin: "me").resolve(records: records, installation: "me"), .host(id: "A", tab: TabId(4), pane: PaneId(9)))
    }

    // MARK: Two windows on one host

    /// A shell stand-in: echoes what is typed, records sizes.
    private final class Shell: PaneBackend, @unchecked Sendable {
        let state = Mutex<(sink: (@Sendable (PaneEvent) -> Void)?, typed: String, sizes: [UInt16], terminated: Bool)>((nil, "", [], false))
        func start(events: @escaping @Sendable (PaneEvent) -> Void) {
            state.withLock { $0.sink = events }
            events(.output(Data("$ ".utf8)))
        }
        func write(_ bytes: UnsafeRawBufferPointer) {
            let text = String(decoding: bytes, as: UTF8.self)
            let sink = state.withLock { state in
                state.typed += text
                return state.sink
            }
            sink?(.output(Data(text.utf8)))
        }
        func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) { state.withLock { $0.sizes.append(cols) } }
        func terminate() { state.withLock { $0.terminated = true } }
    }

    func testTwoWindowsOnOneHostHaveTheirOwnTerminalsAndSelection() throws {
        // One host: two tabs, one shell per pane, shared by both windows.
        var session = Session()  // tab 2: pane 1
        session.apply(.newTab)  // tab 4: pane 3
        let layout = LocalLayoutStore(session: session)
        var shells: [PaneId: SharedPaneBackend] = [:]
        let make: @MainActor (PaneId) throws -> any PaneBackend = { pane in
            if shells[pane] == nil { shells[pane] = SharedPaneBackend(Shell()) }
            return shells[pane]!.makeTap()
        }
        let first = Workspace(layout: layout, selecting: TabId(2), makeBackend: make)
        let second = Workspace(layout: layout, selecting: TabId(4), makeBackend: make)

        // Each window shows its own tab.
        XCTAssertEqual(first.session.activeTabId, TabId(2))
        XCTAssertEqual(second.session.activeTabId, TabId(4))

        // Each window has its own terminal and view for the same pane.
        let a = try XCTUnwrap(first.panes[PaneId(1)])
        let b = try XCTUnwrap(second.panes[PaneId(1)])
        XCTAssertFalse(a === b)
        XCTAssertFalse(a.view === b.view)

        // Typing in either reaches the one shell; both terminals show it.
        a.backend.paste("echo one\r\n")
        b.backend.paste("echo two\r\n")
        let shell = try XCTUnwrap(SharedPaneBackend.underlying(a.backend) as? Shell)
        XCTAssertEqual(shell.state.withLock { $0.typed }, "echo one\r\necho two\r\n")
        XCTAssertTrue(a.view.surface.terminal.plainText().contains("echo two"))
        XCTAssertTrue(b.view.surface.terminal.plainText().contains("echo one"))

        // Selecting a tab in one window leaves the other where it was.
        second.selectTab(TabId(2))
        first.selectTab(TabId(4))
        XCTAssertEqual(first.session.activeTabId, TabId(4))
        XCTAssertEqual(second.session.activeTabId, TabId(2))

        // Closing a window keeps the other's stream; the pane stays in the layout.
        first.close()
        XCTAssertFalse(shell.state.withLock { $0.terminated })
        b.backend.paste("echo three\r\n")
        XCTAssertTrue(b.view.surface.terminal.plainText().contains("echo three"))
        XCTAssertTrue(layout.session.panes.contains(PaneId(1)))

        // Closing the pane in the remaining window ends the shell.
        second.apply(.close(PaneId(1)))
        XCTAssertTrue(shell.state.withLock { $0.terminated })
    }

    func testAPaneOpenedInASecondWindowShowsWhatTheFirstShowed() throws {
        let layout = LocalLayoutStore(session: Session())
        var shells: [PaneId: SharedPaneBackend] = [:]
        let make: @MainActor (PaneId) throws -> any PaneBackend = { pane in
            if shells[pane] == nil { shells[pane] = SharedPaneBackend(Shell()) }
            return shells[pane]!.makeTap()
        }
        let first = Workspace(layout: layout, makeBackend: make)
        let a = try XCTUnwrap(first.panes[PaneId(1)])
        a.backend.paste("printf before\r\n")
        let second = Workspace(layout: layout, makeBackend: make)
        let b = try XCTUnwrap(second.panes[PaneId(1)])
        XCTAssertTrue(b.view.surface.terminal.plainText().contains("printf before"))
    }
}
