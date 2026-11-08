#if os(macOS)
import AppKit
import Darwin
import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// A window left alone does no work on the main thread: a view that changes its own state while
/// it draws keeps SwiftUI updating forever, and a tab switch can turn that into a hang.
@MainActor
final class IdleMainThreadTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private static let settle = Duration.seconds(2)
    private static let measured = Duration.seconds(2)
    private static let idleBudget = Duration.milliseconds(400)

    func testANormalTabIsQuietWhenIdle() async throws {
        try await expectQuiet("normal tab") { _ in }
    }

    func testAMixedTabWithAToolIsQuietWhenIdle() async throws {
        try await expectQuiet("mixed tab with a tool") { model in
            var session = Session()
            session.apply(.split(PaneId(1), .horizontal))
            let id = model.composites.make(fromHost: HostGroups.localId, tab: session.tabs[0])
            model.focus(WindowModel.mixedRef(id))
            model.sheet = .diff
        }
    }

    func testAMixedTabWhoseHostIsGoneIsQuietWhenIdle() async throws {
        try await expectQuiet("mixed tab on a missing host") { model in
            var session = Session()
            session.apply(.split(PaneId(1), .horizontal))
            let id = model.composites.make(fromHost: "host-that-is-not-open", tab: session.tabs[0])
            model.focus(WindowModel.mixedRef(id))
        }
    }

    private func expectQuiet(_ scenario: String, _ arrange: (WindowModel) async -> Void) async throws {
        let model = WindowModel(app: .shared)
        model.start()
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 1180, height: 760),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: AnyView(WindowContent(request: nil, model: model).environment(AppModel.shared)))
        window.orderFrontRegardless()
        defer {
            window.close()
            model.close()
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        await arrange(model)
        try await Task.sleep(for: Self.settle)
        let before = Self.processCPUTime()
        try await Task.sleep(for: Self.measured)
        let busy = Self.processCPUTime() - before
        XCTAssertLessThan(busy, Self.idleBudget, "\(scenario): \(busy) of CPU in \(Self.measured) idle")
    }

    private static func processCPUTime() -> Duration {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Duration.seconds(usage.ru_utime.tv_sec) + .microseconds(usage.ru_utime.tv_usec)
        let system = Duration.seconds(usage.ru_stime.tv_sec) + .microseconds(usage.ru_stime.tv_usec)
        return user + system
    }
}
#endif
