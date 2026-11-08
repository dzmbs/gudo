#if os(iOS)
import DesignSystem
import SwiftUI
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatSelectedTextTests: XCTestCase {
    func testTheSheetUsesOneReadOnlyNativeUnicodeRangeSelector() async throws {
        let phrase = "👩🏽‍💻 e\u{301} 漢字"
        let text = "First paragraph\nChoose \(phrase), not the whole message.\n<script>literal</script>"
        let selection = ChatSelectedText(title: "Select Text", text: text)
        let (window, _) = try host(ChatSelectedTextSheet(selection: selection, openTerminal: {})
            .chromeTheme(ThemeCatalog.theme(named: "Dracula"), windowTheme: .dark))
        defer { close(window) }
        let view = try await selector(in: window)
        XCTAssertEqual(view.text, text)
        XCTAssertEqual(selectionCount(in: window), 1)
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
        XCTAssertFalse(view.allowsEditingTextAttributes)
        XCTAssertEqual(view.dataDetectorTypes, [])
        XCTAssertNotNil(view.textLayoutManager)
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = (text as NSString).range(of: phrase)
        XCTAssertEqual(view.text(in: try XCTUnwrap(view.selectedTextRange)), phrase)
        XCTAssertNotEqual(view.selectedRange.length, (text as NSString).length)
        try capture(window, name: "chat-select-text-dark")
    }

    func testThemeRefreshPreservesNativeSelectionScrollAndIdentity() async throws {
        let text = (0..<4_000).map { "Line \($0): café, 漢字, 👩🏽‍💻 — literal source." }.joined(separator: "\n")
        let selection = ChatSelectedText(title: "Select Text", text: text)
        let (window, controller) = try host(root(selection, scheme: .dark))
        defer { close(window) }
        let view = try await selector(in: window)
        view.selectedRange = (text as NSString).range(of: "Line 40:")
        view.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        let range = view.selectedRange, offset = view.contentOffset, ink = view.textColor
        controller.rootView = AnyView(root(selection, scheme: .light))
        try await Task.sleep(for: .milliseconds(80))
        let refreshed = try await selector(in: window)
        XCTAssertTrue(view === refreshed)
        XCTAssertEqual(view.selectedRange, range)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 1)
        XCTAssertNotEqual(view.textColor, ink)
        XCTAssertEqual(view.text, text)
        XCTAssertGreaterThan(view.contentSize.height, view.bounds.height)
        try capture(window, name: "chat-select-text-light")
    }

    func testANewSnapshotReplacesTextAndDynamicTypeUsesTheDesignScale() async throws {
        let selection = ChatSelectedText(title: "Select Text", text: "Original snapshot")
        let (window, controller) = try host(root(selection, scheme: .dark))
        defer { close(window) }
        let view = try await selector(in: window)
        let size = try XCTUnwrap(view.font).pointSize
        controller.rootView = AnyView(root(.init(title: "Select Text", text: "Replacement snapshot"),
                                          scheme: .dark).dynamicTypeSize(.accessibility2))
        try await Task.sleep(for: .milliseconds(80))
        let replacement = try await selector(in: window)
        XCTAssertEqual(replacement.text, "Replacement snapshot")
        XCTAssertGreaterThan(try XCTUnwrap(replacement.font).pointSize, size)
        XCTAssertFalse(replacement.isEditable)
    }

    private func root(_ selection: ChatSelectedText, scheme: ColorScheme) -> some View {
        ChatSelectedTextSheet(selection: selection, openTerminal: {})
            .chromeTheme(ThemeCatalog.theme(named: scheme == .dark ? "Dracula" : "Apple System Colors Light"),
                         windowTheme: scheme == .dark ? .dark : .light)
    }

    private func host(_ root: some View) throws -> (UIWindow, UIHostingController<AnyView>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: AnyView(root))
        window.frame = scene.screen.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return (window, controller)
    }

    private func selector(in window: UIWindow) async throws -> UITextView {
        for _ in 0..<100 {
            if let view = find(in: window), view.bounds.height > 0 { return view }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Native selection view did not mount")
        throw CancellationError()
    }

    private func find(in view: UIView) -> UITextView? {
        if let text = view as? UITextView, text.accessibilityIdentifier == "chat-selected-text" { return text }
        return view.subviews.lazy.compactMap { self.find(in: $0) }.first
    }

    private func selectionCount(in view: UIView) -> Int {
        let own = view.accessibilityIdentifier == "chat-selected-text" ? 1 : 0
        return view.subviews.reduce(own) { $0 + selectionCount(in: $1) }
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func capture(_ window: UIWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: root.appending(path: name + ".png"))
    }
}
#endif
