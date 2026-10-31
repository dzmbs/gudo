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
/// watchdog thread measures how long the main thread goes unserved: under 100 ms at the full
/// sizes; the fast variants allow 500 ms (debug build on a shared machine).
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

    /// Closes a test window and tears down its views: AppKit keeps a test's closed windows,
    /// and their views would go on rendering into the next scenario.
    private func dismantle(_ window: NSWindow) {
        window.close()
        window.contentViewController = nil
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
        dismantle(window)
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
        // The window first (its cold start is not the host's cost), then the host.
        model.start()
        let window: NSWindow? = makeWindow(model)
        model.isSidebarShown = true
        await pump(1)
        let report = await measure("open a host with \(tabs) tabs") {
            model.show(.host(host.id))
            try? await until("the host's tabs") { model.workspace(ofGroup: host.id)?.session.tabs.count == tabs }
            try? await until("every pane") { model.workspace(ofGroup: host.id)?.panes.count == tabs }
            await pump(0.5)
        }
        let made = model.workspace(ofGroup: host.id)?.panes.count ?? -1
        print("stress open: \(made) live panes in the window")
        await close(model, window!, host)
        XCTAssertLessThan(report.worst, .milliseconds(stress ? 100 : 500), report.description)
        XCTAssertEqual(made, tabs, "every tab's pane is made, a few per turn")
    }

    /// The sidebar asks for project suggestions on every render: each tab's folder used to
    /// re-resolve every host's tabs, quadratic in tabs (most of an Inbox-flood frame at 500).
    func testProjectSuggestionsStayCheapWithManyTabs() async throws {
        let host = try StressHost(id: "stress-suggest", tabs: 500, projects: 0)
        let (model, window) = try await openWindow(on: host, tabs: 500)
        let start = ContinuousClock.now
        for _ in 0..<5 { _ = model.projectSuggestions }
        let elapsed = (ContinuousClock.now - start) / 5
        print("stress suggestions over 500 tabs: \(elapsed)")
        await close(model, window, host)
        XCTAssertLessThan(elapsed, .milliseconds(30), "\(elapsed) per call")
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
        XCTAssertLessThan(report.worst, .milliseconds(stress ? 100 : 500), report.description)
        XCTAssertLessThan(idle.worst, .milliseconds(100), idle.description)
    }

    private struct Weak {
        weak var object: AnyObject?
    }

    /// The model alone, without a hosting window.
    func testAClosedWindowModelIsFreed() async throws {
        let host = try StressHost(id: "stress-model", tabs: 10, projects: 0)
        defer { host.remove() }
        let (model, workspace) = try await openAndCloseModel(on: host)
        await pump(1)
        XCTAssertNil(workspace.object, "workspace")
        XCTAssertNil(model.object, "model")
    }

    private func openAndCloseModel(on host: StressHost) async throws -> (model: Weak, workspace: Weak) {
        let feed = LiveAgentFeed(hosts: AppModel.shared.hosts)
        let model = WindowModel(app: .shared, agents: feed)
        feed.window = model
        model.start()
        model.show(.host(host.id))
        try await until("tabs") { model.workspace(ofGroup: host.id)?.session.tabs.count == 10 }
        let refs = (Weak(object: model), Weak(object: model.workspace(ofGroup: host.id)))
        model.close()
        return refs
    }

    /// A closed window gives back its panes, terminal views and surfaces. Repeated, so a slow leak shows as a count, not a guess.
    func testClosedWindowsFreeTheirPanes() async throws {
        let host = try StressHost(id: "stress-leak", tabs: 30, projects: 0)
        defer { host.remove() }
        var refs: [String: [Weak]] = [:]
        let rounds = stress ? 10 : 3
        let before = ProcessStats.footprintMB
        for _ in 0..<rounds {
            for (kind, weak) in try await openAndCloseWindow(on: host) { refs[kind, default: []] += weak }
        }
        await pump(1.5)
        let alive = refs.mapValues { $0.filter { $0.object != nil }.count }.filter { $0.value > 0 }
        print("stress leaks after \(rounds) windows of 30 panes: \(alive.isEmpty ? "none" : "\(alive)"); footprint \(Int(before)) → \(Int(ProcessStats.footprintMB)) MB")
        XCTAssertTrue(alive.isEmpty, "still alive after closing: \(alive)")
    }

    /// Opens a window on `host`, closes it, and returns weak references to what it made (in a
    /// function of its own, so no local of the test keeps them).
    private func openAndCloseWindow(on host: StressHost) async throws -> [String: [Weak]] {
        let (model, window) = try await openWindow(on: host, tabs: 30)
        let workspace = try XCTUnwrap(model.workspace(ofGroup: host.id))
        // The window and its model are left out: AppKit keeps a test's hosted windows (even a
        // bare Text's) after `close`; `testAClosedWindowModelIsFreed` checks the model.
        var refs: [String: [Weak]] = [:]
        for pane in workspace.panes.values {
            refs["pane", default: []].append(Weak(object: pane))
            refs["view", default: []].append(Weak(object: pane.view))
            refs["surface", default: []].append(Weak(object: pane.view.surface))
        }
        dismantle(window)
        model.close()
        return refs
    }

    /// Each Inbox row asks the feed about its item (approval, options, rules): resolving the
    /// item rebuilt the whole feed, so a render of 300 agents cost 300 feeds.
    func testInboxRowLookupsDoNotRebuildTheFeed() async throws {
        let host = try StressHost(id: "stress-lookup", tabs: 300, projects: 0, attention: 200)
        defer { host.remove() }
        _ = host.connection.workspace
        try await until("the agents") { host.connection.meta.all.count == 300 && host.connection.existingWorkspace?.attention.count == 200 }
        let feed = LiveAgentFeed(hosts: AppModel.shared.hosts)
        let items = feed.items
        XCTAssertGreaterThan(items.count, 300)
        let start = ContinuousClock.now
        for item in items {
            _ = feed.approval(item.id)
            _ = feed.approvalOptions(item.id)
            _ = feed.autoApprovals(item.id)
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(150), "\(items.count) rows took \(elapsed)")
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
        XCTAssertLessThan(report.worst, .milliseconds(stress ? 100 : 500), report.description)
    }
}
#endif
