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
    private static let image = "/work/shots/dashboard.png"
    private static let attachment = "/work/uploads/sketch.png"

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
            try await capturePages("long-", appearance: appearance, items: try longTurn())
            try await capturePages("working-", appearance: appearance, items: try workingTurn(), working: true, limit: 1)
            try await capturePages("draft-", appearance: appearance, items: try longTurn(), limit: 1,
                                   draft: "Also check the iPad layout and tell me what changed.")
            try await capturePages("failed-expanded-", appearance: appearance, items: try failedTurn(), limit: 1,
                                   expanding: ChatRowID(item: "failed", part: 0))
            try await capturePages("folded-open-", appearance: appearance, items: try longTurn(), limit: 1, opensSummary: true)
            try await capturePages("composer-", appearance: appearance, items: try workingTurn(), working: true, limit: 1,
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
            let file = try ChatPhotoFile.prepare(data: Self.dashboardPNG(), name: "dashboard.png")
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

    private func longTurn() throws -> [[String: Any]] {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return [
            item("prompt", at: now - 840_000, origin: "Terminal", body: ["User": [
                "text": "What clock do our 5090s run at? Check both boxes, and write up how the dashboard should change.",
                "attachments": [], "queued": false]]),
            item("think", body: ["Thinking": ["text": NSNull(), "duration_ms": 4_000]]),
            item("t1", body: tool("Shell", title: "Query nvidia-smi on box one", input: #"{"command":"ssh box-one nvidia-smi"}"#)),
            item("t2", body: tool("Shell", title: "Query nvidia-smi on box two", status: "Failed", exit: 255)),
            item("t3", body: tool("Read", title: "Read README.md", input: #"{"file_path":"/work/README.md"}"#)),
            item("t4", body: tool("Shell", title: "Retry box two over the relay")),
            item("t5", body: tool("Search", title: "Grep for clock settings")),
            item("reply", body: ["Assistant": ["text": Self.longReply, "streaming": false]]),
            item("shot", body: tool("Read", title: "Read dashboard.png", input: #"{"file_path":"\#(Self.image)"}"#)),
            item("after", body: ["Assistant": ["text": "The starter page is close. I am fixing the link colour and the KPI label that wraps, then checking dark mode.",
                                               "streaming": false]]),
            item("e1", body: tool("Edit", title: "Edit dashboard.css", input: #"{"file_path":"/work/dashboard.css"}"#)),
            item("e2", body: tool("Edit", title: "Edit kpi.html", input: #"{"file_path":"/work/kpi.html"}"#)),
            item("end", body: ["TurnEnd": ["duration_ms": 94_000, "input_tokens": 61_000, "output_tokens": 3_100]]),
        ]
    }

    private func workingTurn() throws -> [[String: Any]] {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return [
            item("second-prompt", at: now - 19_000, body: ["User": [
                "text": "Read the guideline PDF in full and fix the dashboard. Gad is really checking this, so take care with every detail.",
                "attachments": [["path": Self.attachment, "media_type": "image/png"]], "queued": false]]),
            item("r1", body: tool("Shell", title: "List the kit files")),
            item("r2", body: tool("Read", title: "Read guideline.pdf")),
            item("r3", body: tool("Read", title: "Read starter.html")),
            item("r4", body: tool("Shell", title: "Run the page checks", status: "Running")),
            item("note", body: ["Assistant": ["text": "I am reading the guideline and the starter page before touching any code.",
                                              "streaming": true]]),
        ]
    }

    private func failedTurn() throws -> [[String: Any]] {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        return [
            item("prompt", at: now - 120_000, body: ["User": ["text": "Run the proto tests.", "attachments": [], "queued": false]]),
            item("failed", body: tool("Shell", title: "Run the proto tests", input: #"{"command":"cargo test -p proto"}"#,
                                      status: "Failed", exit: 101, output: """
                                      running 42 tests
                                      test golden::timeline_items ... ok
                                      test golden::tool_kinds ... FAILED

                                      failures:
                                          golden::tool_kinds: left: 9, right: 10
                                      test result: FAILED. 41 passed; 1 failed
                                      """)),
            item("reply", body: ["Assistant": ["text": "One golden test fails: a new tool kind was appended without its byte. I will add it.",
                                               "streaming": false]]),
        ]
    }

    private static let longReply = """
    ## Clocks on both boxes

    Measured live on both boxes. The cards boost well past their base clock and stay under the power limit, so nothing is throttling. Readings come from `nvidia-smi --query-gpu=clocks.sm,clocks.mem --format=csv` on each box.

    | | Now | Card maximum |
    |---|---|---|
    | GPU core (SM) clock | **2,570 to 2,595 MHz** | 3,090 MHz |
    | Memory clock | 13,801 MHz | 14,001 MHz |
    | Power draw under load | 545 to 575 W | 575 W |

    ### What to change

    1. Show the **live clock** next to each card, not the base clock.
    2. Mark a card amber when it sits under `2,400 MHz` for a minute.
    3. Keep the power column, and add the limit as a faint rule.

    - The same reading drives the sparkline.
    - Nothing else on the page moves.

    > Both boxes run the same driver, 580.82, so the numbers compare directly.

    The card model reads its clock like this:

    ```swift
    struct GPUClock: Decodable {
        let core: Measurement<UnitFrequency>
        let memory: Measurement<UnitFrequency>

        var isBoosting: Bool { core.value > 2_400 }
    }
    ```

    Here is the dashboard before the change:
    """

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
        let snapshot = try TimelineFixtureJSON.json([
            "capabilities": 447, "cursor": ["epoch": 1, "sequence": 0], "before": NSNull(), "items": items,
            "session": ["agent": "Claude", "native_session": nativeSession, "title": "Review the change",
                        "model": "claude-opus-4-5-20251101", "permission_mode": "auto", "commands": []],
        ])
        let client = TimelineFixtureClient(snapshot: snapshot, nativeMessageReceipts: true)
        client.state.withLock { files in
            files.files[Self.image] = Self.dashboardPNG()
            files.files[Self.attachment] = Self.dashboardPNG()
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

    private func tool(_ kind: String, title: String, input: String = "{}", status: String = "Done", exit: Int? = nil,
                      output: String? = nil) -> [String: Any] {
        let reference: Any = output.map { ["handle": "fixture", "preview": $0, "bytes": $0.utf8.count] } ?? NSNull()
        return ["Tool": ["kind": kind, "name": kind, "title": title, "input": input, "status": status, "output": reference,
                         "diff": [], "exit": exit.map { $0 as Any } ?? NSNull(), "duration_ms": 1_200, "command_mark": NSNull()]]
    }

    private func item(_ id: String, at: UInt64 = 0, origin: String = "Agent", body: [String: Any]) -> [String: Any] {
        ["id": id, "revision": 1, "turn": "turn", "parent": NSNull(), "at": at, "origin": origin, "body": body]
    }

    private static func dashboardPNG() -> Data {
        let size = CGSize(width: 1_200, height: 700)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.96, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 56))
            UIColor(white: 0.86, alpha: 1).setFill()
            for column in 0..<6 {
                context.fill(CGRect(x: 40 + CGFloat(column) * 190, y: 90, width: 170, height: 90))
            }
            UIColor(red: 0.29, green: 0.62, blue: 0.64, alpha: 1).setFill()
            for (column, height) in [60, 90, 130, 170, 210, 250, 290, 330, 80, 140].enumerated() {
                context.fill(CGRect(x: 60 + CGFloat(column) * 110, y: size.height - 40 - CGFloat(height), width: 70, height: CGFloat(height)))
            }
        }
        return image.pngData() ?? Data()
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
