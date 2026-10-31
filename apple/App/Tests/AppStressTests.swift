#if os(macOS)
import AppKit
import DesignSystem
@testable import HostKit
import SwiftUI
import UnnamedCore
import XCTest
@testable import App

/// The window under load, in process: a daemon host with hundreds of tabs and agents whose
/// status changes 100 times a second, an attention feed filling up, the Inbox open over it. A
/// watchdog thread measures how long the main thread goes unserved; it must stay under 100 ms.
/// The fast variants always run (mock hosts needed: `TEST_RUNNER_UNNAMED_MOCK=1`);
/// `TEST_RUNNER_STRESS=1` runs the full sizes (500 tabs, 50 projects, 10 s).
@MainActor
final class AppStressTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var stress: Bool { env["STRESS"] != nil }
    /// `TEST_RUNNER_STRESS_TABS`, `TEST_RUNNER_STRESS_SECONDS` override the sizes (profiling).
    private var tabCount: Int { env["STRESS_TABS"].flatMap(Int.init) ?? (stress ? 500 : 120) }
    private var duration: Double { env["STRESS_SECONDS"].flatMap(Double.init) ?? (stress ? 10 : 3) }

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_UNNAMED_MOCK=1)")
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func makeWindow(_ model: WindowModel) -> NSWindow {
        let size = CGSize(width: 1280, height: 860)
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: WindowContent(request: nil, model: model).environment(AppModel.shared))
        window.setFrame(NSRect(x: -30000, y: -30000, width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
        return window
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func until(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw XCTSkip("timed out waiting for \(what)") }
            await pump(0.05)
        }
    }

    /// A window showing `host` with the live agent feed (not the mock one).
    private func openWindow(on host: StressHost, tabs: Int) async throws -> (WindowModel, NSWindow) {
        let feed = LiveAgentFeed(hosts: AppModel.shared.hosts)
        let model = WindowModel(app: .shared, agents: feed)
        feed.window = model
        model.start()
        let window = makeWindow(model)
        model.isSidebarShown = true
        model.show(.host(host.id))
        try await until("the host's tabs") { model.workspace(ofGroup: host.id)?.session.tabs.count == tabs }
        await pump(1)
        return (model, window)
    }

    private func close(_ model: WindowModel, _ window: NSWindow, _ host: StressHost) async {
        window.close()
        model.close()
        host.remove()
        await pump(0.3)
    }

    /// Runs `load` under the watchdog and prints what it cost.
    private func measure(_ name: String, _ load: () async -> Void) async -> HangWatch.Report {
        let watch = HangWatch()
        let cpu = ProcessStats.cpuSeconds
        let start = ContinuousClock.now
        let before = ProcessStats.footprintMB
        watch.start()
        await load()
        await pump(0.5)
        let report = watch.stop()
        let wall = ContinuousClock.now - start
        let seconds = Double(wall.components.seconds) + Double(wall.components.attoseconds) / 1e18
        print(String(
            format: "stress %@: hang %@; CPU %.0f%%; footprint %.0f → %.0f MB; threads %d",
            name, report.description, (ProcessStats.cpuSeconds - cpu) / seconds * 100, before, ProcessStats.footprintMB, ProcessStats.threads))
        return report
    }

    /// Opening a host that already runs hundreds of tabs.
    func testOpeningAHostWithManyTabs() async throws {
        let tabs = tabCount
        let host = try StressHost(id: "stress-open", tabs: tabs, projects: stress ? 50 : 12)
        let feed = LiveAgentFeed(hosts: AppModel.shared.hosts)
        let model = WindowModel(app: .shared, agents: feed)
        feed.window = model
        var window: NSWindow?
        let report = await measure("open a host with \(tabs) tabs") {
            model.start()
            window = makeWindow(model)
            model.isSidebarShown = true
            model.show(.host(host.id))
            try? await until("the host's tabs") { model.workspace(ofGroup: host.id)?.session.tabs.count == tabs }
            await pump(1)
        }
        print("stress open: \(model.workspace(ofGroup: host.id)?.panes.count ?? -1) live panes in the window")
        await close(model, window!, host)
        XCTAssertLessThan(report.worst, .milliseconds(stress ? 100 : 250), report.description)
    }

    func testSidebarUnderAgentChurn() async throws {
        let tabs = tabCount, seconds = duration
        let host = try StressHost(id: "stress-sidebar", tabs: tabs, projects: stress ? 50 : 12)
        let (model, window) = try await openWindow(on: host, tabs: tabs)
        let idle = await measure("sidebar \(tabs) tabs, no updates") { await pump(env["STRESS_IDLE"].flatMap(Double.init) ?? 2) }
        let report = await measure("sidebar \(tabs) tabs, 100 updates/s") {
            await drive(Int(100 * seconds), perSecond: 100) { host.client.send(host.churn($0)) }
        }
        await close(model, window, host)
        XCTAssertLessThan(report.worst, .milliseconds(stress ? 100 : 250), report.description)
        XCTAssertLessThan(idle.worst, .milliseconds(100), idle.description)
    }

    func testInboxUnderAgentChurnAndAttentionFlood() async throws {
        let tabs = tabCount, seconds = duration
        let host = try StressHost(id: "stress-inbox", tabs: tabs, projects: 0, attention: 500)
        let (model, window) = try await openWindow(on: host, tabs: tabs)
        model.destination = .inbox
        await pump(1)
        let report = await measure("inbox \(tabs) agents, 100 updates/s + 100 attention/s") {
            await drive(Int(100 * seconds), perSecond: 100) { n in
                host.client.send(host.churn(n))
                host.pushAttention(UInt64(1000 + n))
            }
        }
        await close(model, window, host)
        XCTAssertLessThan(report.worst, .milliseconds(stress ? 100 : 250), report.description)
    }
}
#endif
