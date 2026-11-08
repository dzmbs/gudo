#if os(iOS)
import DesignSystem
import Darwin
import HostKit
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatCollectionTests: XCTestCase {
    private func preparedFrame(_ count: Int, prefix: String = "row") -> TimelineFrame {
        let rows = (0..<count).map { index in
            let text = "Entry \(index). Native rows keep finished text in place while the next response arrives."
            let block = ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))
            return ChatRow(id: ChatRowID(item: "\(prefix)-\(index)", part: 0), revision: 1, turn: "turn", content: .markdown(block))
        }
        return TimelineFrame(rows: rows, rowIDs: Set(rows.map(\.id)), revision: 1)
    }

    private func open(_ frame: TimelineFrame, following: Bool = true,
                      onSnapshot: ((ChatViewController) -> Void)? = nil) throws -> (UIWindow, ChatViewController) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let model = TimelineModel(pane: 42)
        model.followsBottom = following
        let controller = ChatViewController(model: model)
        controller.loadViewIfNeeded()
        controller.onSnapshot = { [weak controller] _ in
            if let controller { onSnapshot?(controller) }
        }
        update(controller, frame)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
        return (window, controller)
    }

    private func update(_ controller: ChatViewController, _ frame: TimelineFrame, expanded: Set<ChatRowID> = [], isActive: Bool = true, environment: EnvironmentValues = EnvironmentValues()) {
        controller.update(frame: frame, expanded: expanded, environment: environment, actions: ChatRowActions(),
                          composer: AnyView(Text("Message Claude").font(.body).padding(20).frame(maxWidth: .infinity, alignment: .leading)), isActive: isActive)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(160)) }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    func testParkingChatVetoesMarkedComposerTextBeforeResigning() throws {
        let (window, controller) = try open(preparedFrame(1))
        defer { close(window) }
        let editor = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        controller.view.addSubview(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        XCTAssertFalse(controller.prepareToPark())
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertNotNil(editor.markedTextRange)
        editor.unmarkText()
        XCTAssertTrue(controller.prepareToPark())
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertEqual(editor.text, "かな")
    }

    func testOversizedMessageHasABoundedNativeTerminalFallback() async throws {
        let row = ChatRow(id: ChatRowID(item: "omitted", part: 0), revision: 1, turn: "turn", content: .omitted)
        let frame = TimelineFrame(rows: [row], rowIDs: [row.id], revision: 1)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        XCTAssertEqual(controller.collection.numberOfItems(inSection: 0), 1)
        let height = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame.height
        XCTAssertGreaterThan(height, DS.Size.touchTarget)
        XCTAssertLessThan(height, 300)
        if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            let destination = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-chat-omitted.png")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: destination)
        }
    }

    func testVisibleRowsHaveFittingHeightsBeforeTheirFirstSnapshot() async throws {
        var measuredAtSubmission: [Int] = []
        let (window, _) = try open(preparedFrame(3), onSnapshot: { measuredAtSubmission.append($0.measuredCells) })
        defer { close(window) }
        try await settle()
        XCTAssertFalse(measuredAtSubmission.isEmpty)
        XCTAssertTrue(measuredAtSubmission.allSatisfy { $0 >= 3 }, "Visible rows must fit before UIKit receives their snapshot")
    }

    func testScrollingRevealsRowsWithFittedGeometryBeforeTheyAreDisplayed() async throws {
        let (window, controller) = try open(preparedFrame(800), following: false)
        defer { close(window) }
        try await settle()
        for index in [300, 500, 200] { assertFittedScroll(index, controller: controller) }
    }

    func testRevealedCodeTablesAndToolsAlsoFitBeforeDisplay() async throws {
        let fixture = try await ChatTestFixtures.conversation()
        let rows = (0..<20).flatMap { batch in fixture.rows.map { row in
            ChatRow(id: ChatRowID(item: "\(batch):\(row.id.item)", part: row.id.part), revision: row.revision,
                    turn: row.turn, content: row.content)
        } }
        let frame = TimelineFrame(rows: rows, rowIDs: Set(rows.map(\.id)), revision: 1)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        for index in [rows.count / 2, rows.count * 3 / 4, rows.count / 4] {
            assertFittedScroll(index, controller: controller)
        }
    }

    private func assertFittedScroll(_ index: Int, controller: ChatViewController) {
        let before = controller.unfittedDisplays
        let configured = controller.configuredCells
        let target = IndexPath(item: index, section: 0)
        controller.collection.scrollToItem(at: target, at: .top, animated: false)
        controller.collection.layoutIfNeeded()
        XCTAssertTrue(controller.collection.indexPathsForVisibleItems.contains(target))
        XCTAssertGreaterThan(controller.configuredCells, configured)
        XCTAssertEqual(controller.unfittedDisplays, before, "Revealed rows must fit before willDisplay, not a later frame")
    }

    func testVisibleRevisionsFitBeforeTheirSnapshotReconfiguration() async throws {
        var frame = preparedFrame(3)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        let before = controller.measuredCells
        var measuredAtSubmission: Int?
        controller.onSnapshot = { [weak controller] _ in measuredAtSubmission = controller?.measuredCells }
        let previous = frame.rows[0]
        let text = String(repeating: "The changed row must fit before its new content is displayed. ", count: 20)
        frame.rows[0] = ChatRow(id: previous.id, revision: 2, turn: previous.turn,
            content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))))
        frame.parentRevision = frame.revision
        frame.changedRows = [frame.rows[0]]
        frame.revision += 1
        update(controller, frame)
        try await settle()
        XCTAssertGreaterThan(try XCTUnwrap(measuredAtSubmission), before)
    }

    func testMeasurementMarkersDoNotOutliveTheRetainedRows() async throws {
        var frame = preparedFrame(1)
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        for index in 0..<4 {
            frame.rows = preparedFrame(1, prefix: "replacement-\(index)").rows
            frame.rowIDs = Set(frame.rows.map(\.id))
            frame.revision += 1
            update(controller, frame)
            try await settle()
        }
        XCTAssertEqual(controller.retainedMeasurementCount, 1)
    }

    func testHeightCacheChargesRetainedIdentifierBytes() async throws {
        let original = preparedFrame(1).rows[0]
        let row = ChatRow(id: ChatRowID(item: String(repeating: "id", count: 50_000), part: 0),
                          revision: 1, turn: original.turn, content: original.content)
        let frame = TimelineFrame(rows: [row], rowIDs: [row.id], revision: 1)
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        XCTAssertGreaterThanOrEqual(controller.retainedHeightBytes, row.id.item.utf8.count)
    }

    func testPrependingKeepsTheReadingRowAtTheSamePosition() async throws {
        var frame = preparedFrame(200)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        let original = IndexPath(item: 120, section: 0)
        controller.collection.scrollToItem(at: original, at: .top, animated: false)
        try await settle()
        let before = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: original)).frame.minY - controller.collection.contentOffset.y
        let older = preparedFrame(100, prefix: "older").rows
        frame.rows.insert(contentsOf: older, at: 0)
        frame.rowIDs.formUnion(older.map(\.id))
        frame.revision += 1
        update(controller, frame)
        try await settle()
        let after = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: IndexPath(item: 220, section: 0))).frame.minY - controller.collection.contentOffset.y
        XCTAssertEqual(after, before, accuracy: 0.5)
        XCTAssertEqual(controller.collection.numberOfItems(inSection: 0), 300)
    }

    func testBottomFollowingAndReadingProtection() async throws {
        var frame = preparedFrame(200)
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        func bottomDistance() -> CGFloat {
            controller.collection.contentSize.height - controller.collection.bounds.height + controller.collection.adjustedContentInset.bottom - controller.collection.contentOffset.y
        }
        XCTAssertEqual(bottomDistance(), 0, accuracy: 1)
        let more = preparedFrame(5, prefix: "new").rows
        frame.rows += more
        frame.rowIDs.formUnion(more.map(\.id))
        frame.revision += 1
        update(controller, frame)
        try await settle()
        XCTAssertEqual(bottomDistance(), 0, accuracy: 1)
        controller.model.followsBottom = false
        controller.collection.scrollToItem(at: IndexPath(item: 90, section: 0), at: .top, animated: false)
        try await settle()
        let readingOffset = controller.collection.contentOffset.y
        let previous = frame.rows[204]
        frame.rows[204] = ChatRow(id: previous.id, revision: previous.revision + 1, turn: previous.turn, content: previous.content)
        frame.revision += 1
        update(controller, frame)
        try await settle()
        XCTAssertEqual(controller.collection.contentOffset.y, readingOffset, accuracy: 1)
        XCTAssertFalse(controller.model.followsBottom)
    }

    func testTheLatestGapKeepsItsJumpControlAtTheLoadedBottom() async throws {
        var frame = preparedFrame(200)
        frame.hasNewerGap = true
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        controller.collection.scrollToItem(at: IndexPath(item: 199, section: 0), at: .bottom, animated: false)
        try await settle()
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        XCTAssertTrue(controller.model.followsBottom)
        let control = try XCTUnwrap(controller.view.subviews.first { $0.accessibilityIdentifier == "chat-jump-latest" })
        XCTAssertFalse(control.isHidden, "The loaded bottom is not the live bottom when newer values were evicted")
        XCTAssertNotNil(controller.model.readingItem)
    }

    func testAChangedTailDoesNotReconfigureFinishedVisibleRows() async throws {
        var frame = preparedFrame(5)
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        let configured = controller.configuredCells
        let measured = controller.measuredCells
        let path = IndexPath(item: 4, section: 0)
        let height = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame.height
        let previous = frame.rows[4]
        let text = String(repeating: "The updated tail grows while finished rows keep their cached geometry. ", count: 6)
        frame.rows[4] = ChatRow(id: previous.id, revision: previous.revision + 1, turn: previous.turn,
                                content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))))
        frame.parentRevision = frame.revision
        frame.changedRows = frame.rows
        frame.revision += 1
        update(controller, frame)
        try await settle()
        XCTAssertEqual(controller.configuredCells - configured, 1)
        XCTAssertEqual(controller.measuredCells - measured, 1)
        XCTAssertGreaterThan(try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame.height, height)
    }

    func testOffscreenChangedRowsAreReconfiguredInTheSnapshot() async throws {
        var frame = preparedFrame(200)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        var reconfigured: Set<ChatRowID> = []
        controller.onSnapshot = { reconfigured.formUnion($0.reconfiguredItemIdentifiers) }
        let index = 150
        XCTAssertFalse(controller.collection.indexPathsForVisibleItems.contains(IndexPath(item: index, section: 0)))
        let previous = frame.rows[index]
        frame.rows[index] = ChatRow(id: previous.id, revision: 2, turn: previous.turn,
            content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: "Finished offscreen", text: AttributedString("Finished offscreen"))))
        frame.parentRevision = frame.revision
        frame.revision += 1
        frame.changedRows = [frame.rows[index]]
        update(controller, frame)
        try await settle()
        XCTAssertTrue(reconfigured.contains(previous.id))
    }

    func testRestylingReconfiguresOffscreenRowsToo() async throws {
        let frame = preparedFrame(200)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        var reconfigured: Set<ChatRowID> = []
        controller.onSnapshot = { reconfigured.formUnion($0.reconfiguredItemIdentifiers) }
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = .accessibility3
        update(controller, frame, environment: environment)
        try await settle()
        XCTAssertEqual(reconfigured, frame.rowIDs)
    }

    func testGenerationChangesRefreshEvenWhenCursorsAndRevisionsMatch() async throws {
        var frame = preparedFrame(5)
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        let configured = controller.configuredCells
        frame.generation = UUID()
        let previous = frame.rows[4]
        frame.rows[4] = ChatRow(id: previous.id, revision: previous.revision, turn: previous.turn,
                                content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: "Another host.", text: AttributedString("Another host."))))
        update(controller, frame)
        try await settle()
        XCTAssertGreaterThan(controller.configuredCells, configured)
    }

    func testCachedLargeWindowCreatesOnlyVisibleCells() async throws {
        let frame = preparedFrame(2_000)
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        XCTAssertEqual(controller.collection.numberOfItems(inSection: 0), 2_000)
        XCTAssertLessThan(controller.configuredCells, 60)
        XCTAssertLessThan(controller.collection.visibleCells.count, 40)
        let latency = try XCTUnwrap(controller.firstContentLatency)
        print("Chat cached open: \(latency) ms, first apply: \(controller.applyDurations.first ?? 0) ms,",
              "configured: \(controller.configuredCells), fitted: \(controller.measuredCells)")
        XCTAssertLessThan(latency, 100)
    }

    func testStreamingApplyBudgetForALargeCachedWindow() async throws {
        var frame = preparedFrame(2_000)
        frame.orderRevision = 1
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        let baseline = controller.applyDurations.count
        for index in 1...100 {
            let previous = frame.rows[1_999]
            let text = "Updated answer \(index). Each native row updates without disturbing finished paragraphs."
            frame.rows[1_999] = ChatRow(id: previous.id, revision: previous.revision + 1, turn: previous.turn,
                                       content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: text, text: AttributedString(text))))
            frame.parentRevision = frame.revision
            frame.changedRows = [frame.rows[1_999]]
            frame.revision += 1
            update(controller, frame)
            try await Task.sleep(for: .milliseconds(35))
        }
        try await settle()
        let samples = controller.applyDurations.dropFirst(baseline).sorted()
        XCTAssertGreaterThan(samples.count, 90)
        guard !samples.isEmpty else { return XCTFail("No native apply samples") }
        let index = max(0, Int(ceil(Double(samples.count) * 0.99)) - 1)
        let percentile = samples[index]
        print("Chat streaming apply p99: \(percentile) ms (\(samples.count) samples)")
        XCTAssertLessThan(percentile, 4)
    }

    func testDynamicTypeOverridesInvalidateVisibleGeometry() async throws {
        let frame = preparedFrame(20)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        let path = IndexPath(item: 0, section: 0)
        let height = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame.height
        let measured = controller.measuredCells
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = .accessibility3
        update(controller, frame, environment: environment)
        try await settle()
        let expanded = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame.height
        XCTAssertGreaterThan(expanded, height)
        XCTAssertGreaterThan(controller.measuredCells, measured)
    }

    func testInactivePresentationParksTheClockAndCatchesUpWhenShown() async throws {
        var frame = preparedFrame(200)
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        let configured = controller.configuredCells
        let more = preparedFrame(5, prefix: "new").rows
        frame.rows += more
        frame.rowIDs.formUnion(more.map(\.id))
        frame.revision += 1
        update(controller, frame, isActive: false)
        try await settle()
        XCTAssertEqual(controller.collection.numberOfItems(inSection: 0), 200)
        XCTAssertEqual(controller.configuredCells, configured)
        update(controller, frame)
        try await settle()
        XCTAssertEqual(controller.collection.numberOfItems(inSection: 0), 205)
        XCTAssertGreaterThan(controller.configuredCells, configured)
    }

    func testCoalescedFramesDoNotLoseEarlierChanges() async throws {
        var frame = preparedFrame(5)
        frame.orderRevision = 1
        let (window, controller) = try open(frame)
        defer { close(window) }
        try await settle()
        let configured = controller.configuredCells
        let measured = controller.measuredCells
        for index in [0, 4] {
            let previous = frame.rows[index]
            frame.rows[index] = ChatRow(id: previous.id, revision: 2, turn: previous.turn,
                                        content: .markdown(ChatMarkdownBlock(kind: .paragraph, source: "Changed \(index).", text: AttributedString("Changed \(index)."))))
        }
        frame.parentRevision = frame.revision + 1
        frame.revision += 2
        frame.changedRows = [frame.rows[4]]
        update(controller, frame)
        try await settle()
        XCTAssertEqual(controller.configuredCells - configured, 2)
        XCTAssertEqual(controller.measuredCells - measured, 2)
    }

    private func residentBytes() throws -> UInt64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        return information.resident_size
    }

    func testScrollingTwiceKeepsMemoryAndMeasurementsFlat() async throws {
        let baseline = try residentBytes()
        let frame = preparedFrame(2_000)
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        func scroll() async throws {
            for index in stride(from: 0, to: 2_000, by: 10) {
                controller.collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
                try await Task.sleep(for: .milliseconds(18))
            }
            try await settle()
        }
        try await scroll()
        let first = try residentBytes()
        let measured = controller.measuredCells
        try await scroll()
        let second = try residentBytes()
        let aboveBaseline = second > baseline ? second - baseline : 0
        let growth = second > first ? second - first : 0
        print("Chat scroll memory above baseline: \(aboveBaseline), second-pass growth: \(growth)")
        XCTAssertLessThan(aboveBaseline, 80 * 1_024 * 1_024)
        XCTAssertLessThan(growth, 8 * 1_024 * 1_024)
        XCTAssertLessThan(controller.measuredCells - measured, 40)
        XCTAssertLessThan(controller.collection.visibleCells.count, 40)
    }

    func testPartiallyVisibleRowsDoNotRelayoutForContainerSafeAreas() async throws {
        var frame = try await ChatTestFixtures.conversation()
        let padding = preparedFrame(50, prefix: "padding").rows
        frame.rows += padding
        frame.rowIDs.formUnion(padding.map(\.id))
        let (window, controller) = try open(frame, following: false)
        defer { close(window) }
        try await settle()
        let index = try XCTUnwrap(frame.rows.firstIndex { row in
            if case .markdown(let block) = row.content, block.kind == .list { return true }
            return false
        })
        let path = IndexPath(item: index, section: 0)
        func rendered(at y: CGFloat) async throws -> Data {
            let position = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame.minY
            controller.collection.setContentOffset(CGPoint(x: 0, y: position - y), animated: false)
            try await settle()
            let cell = try XCTUnwrap(controller.collection.cellForItem(at: path))
            let image = UIGraphicsImageRenderer(bounds: cell.bounds).image { _ in
                cell.drawHierarchy(in: cell.bounds, afterScreenUpdates: true)
            }
            return try XCTUnwrap(image.pngData())
        }
        let belowChrome = try await rendered(at: 200)
        let beneathChrome = try await rendered(at: 0)
        XCTAssertEqual(beneathChrome, belowChrome)
    }

    func testConversationRowsRenderAcrossChromeAndTerminalSchemes() async throws {
        let frame = try await ChatTestFixtures.conversation()
        for themeName in ["Dracula", "Apple System Colors Light"] {
            for scheme in [ColorScheme.dark, .light] {
                let (window, controller) = try open(frame, following: false)
                defer { close(window) }
                let theme = ThemeCatalog.theme(named: themeName)
                var environment = EnvironmentValues()
                environment.terminalTheme = theme
                environment.chrome = ChromePalette(theme: theme, scheme: scheme)
                environment.colorScheme = scheme
                window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                let expanded = frame.rowIDs
                update(controller, frame, expanded: expanded, environment: environment)
                try await settle()
                for index in frame.rows.indices {
                    controller.collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
                    try await Task.sleep(for: .milliseconds(25))
                }
                try await settle()
                XCTAssertEqual(controller.collection.numberOfItems(inSection: 0), frame.rows.count)
                for path in controller.collection.indexPathsForVisibleItems {
                    let height = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame.height
                    XCTAssertTrue(height.isFinite && height > 0 && height < 2_000)
                }
                if let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] {
                    let code = frame.rows.firstIndex { row in
                        if case .markdown(let block) = row.content, case .code = block.kind { return true }
                        return false
                    } ?? 0
                    for (label, index) in [("start", 0), ("code", code), ("tools", frame.rows.count - 1)] {
                        controller.collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
                        try await settle()
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
                        let mode = scheme == .dark ? "dark" : "light"
                        let themeLabel = themeName.lowercased().replacingOccurrences(of: " ", with: "-")
                        let destination = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-chat-rows-\(label)-\(themeLabel)-\(mode).png")
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try XCTUnwrap(image.pngData()).write(to: destination)
                    }
                }
            }
        }
    }

    func testDisplayClockDoesNotRetainAClosedController() async throws {
        let frame = preparedFrame(10)
        var result: (UIWindow, ChatViewController)? = try open(frame)
        weak var controller = result?.1
        try await settle()
        if let window = result?.0 { close(window) }
        result = nil
        try await settle()
        XCTAssertNil(controller)
    }
}

@MainActor
enum ChatTestFixtures {
    static func conversation() async throws -> TimelineFrame {
        let markdown = """
        # A smaller change

        Keep **finished rows** in place and use [native controls](https://example.com).

        - Decode values off the main actor
        - Reuse visible cells

        > The terminal keeps running.

        ```swift
        func update(_ frame: Frame) {
            collection.apply(frame)
        }
        ```

        | Check | Result |
        | --- | --- |
        | Layout | Passed |
        | History | Anchored |

        ---

        <details>Literal HTML, not a web view.</details>
        """
        let bodies: [[String: Any]] = [
            ["User": ["text": "Review the list update and keep the terminal running.", "attachments": [["path": "diagram.png", "media_type": "image/png"]], "queued": false]],
            ["Thinking": ["text": "Check the row identities before changing geometry.", "duration_ms": 1_200]],
            ["Assistant": ["text": markdown, "streaming": false]],
            ["Tool": ["kind": "Shell", "name": "Bash", "title": "cargo test", "input": "cargo test", "status": "Succeeded", "diff": [], "exit": 0, "duration_ms": 840,
                      "output": ["handle": "fixture-output", "preview": "running 42 tests\ntest result: ok. 42 passed", "bytes": 57]]],
            ["Tool": ["kind": "Search", "name": "Grep", "title": "Checking references", "input": "timeline", "status": "Running", "diff": []]],
            ["Plan": ["entries": [["text": "Cache the completed rows", "status": "Completed"], ["text": "Check reading anchors", "status": "InProgress"], ["text": "Review both colour schemes", "status": "Pending"]]]],
            ["Notice": ["kind": "Info", "text": "Context compacted. Earlier messages remain in history."]],
            ["TurnEnd": ["duration_ms": 13_500, "input_tokens": 1_024, "output_tokens": 184]]
        ]
        let builder = RowBuilder()
        var rows: [ChatRow] = []
        for (index, body) in bodies.enumerated() {
            let value: [String: Any] = ["id": "fixture-\(index)", "revision": 1, "turn": "fixture-turn", "at": 1_700_000_000_000,
                                        "origin": index == 0 ? "Terminal" : "Agent", "body": body]
            let data = try JSONSerialization.data(withJSONObject: value)
            let item = try TimelineJSON.decode(TimelineItem.self, from: String(decoding: data, as: UTF8.self))
            rows += await builder.rows(for: item)
        }
        return TimelineFrame(rows: rows, rowIDs: Set(rows.map(\.id)), revision: 1)
    }
}
#endif
