#if os(iOS)
import DesignSystem
import UIKit
import XCTest
@testable import App

/// The key bar's decision strip: an option's label stays on one line in the key bar's own font.
@MainActor
final class KeyBarDecisionTests: XCTestCase {
    private static let longLabel = "At 09:12 UTC two of the new outside miners started reporting stale shares again"

    func testALongLabelIsOneTruncatedLineInTheKeyFont() throws {
        let style = KeyBarStyle.designSystem
        let button = LineEditorController.decisionButton(title: Self.longLabel, index: 1, style: style)
        let strip = UIStackView(arrangedSubviews: [button, LineEditorController.decisionButton(title: "Yes", index: 0, style: style)])
        strip.distribution = UIStackView.Distribution.fillEqually
        strip.frame = CGRect(x: 0, y: 0, width: 300, height: 52)
        strip.layoutIfNeeded()

        let title = try XCTUnwrap(button.titleLabel)
        let keyTitle = try XCTUnwrap(KeyBarLook.configuration(title: "esc", symbol: nil, active: false, isPad: false).attributedTitle)
        let font = try XCTUnwrap(NSAttributedString(keyTitle).attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(title.font.pointSize, font.pointSize, accuracy: 0.5, "the key bar's normal key font")
        XCTAssertEqual(title.numberOfLines, 1)
        XCTAssertEqual(title.lineBreakMode, NSLineBreakMode.byTruncatingTail)
        XCTAssertLessThan(title.bounds.height, title.font.lineHeight * 1.5, "one line, not wrapped")
        XCTAssertLessThanOrEqual(button.bounds.height, strip.bounds.height)
        XCTAssertEqual(button.accessibilityLabel, Self.longLabel, "VoiceOver hears the whole label")
        XCTAssertEqual(button.accessibilityIdentifier, "keybar-decision-1")
    }

    /// The strip drawn to `SNAPSHOT_DIR` as `iphone-keybar-decisions-<SNAPSHOT_MODE>.png`.
    func testCaptureTheDecisionStrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["SNAPSHOT_DIR"] == nil, "snapshots run on request")
        let directory = try XCTUnwrap(environment["SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) })
        let mode = environment["SNAPSHOT_MODE"] ?? "dark"
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 120)
        window.overrideUserInterfaceStyle = mode == "light" ? .light : .dark
        let controller = UIViewController()
        controller.view.backgroundColor = mode == "light" ? .white : .black // style-exempt: a plain field behind the glass keys
        window.rootViewController = controller
        let style = KeyBarStyle.designSystem
        let labels = ["Yes", Self.longLabel, "Yes, and don't ask again for this command in this project", "No, and tell Claude what to do differently"]
        let strip = UIStackView(arrangedSubviews: labels.enumerated().map { LineEditorController.decisionButton(title: $1, index: $0, style: style) })
        strip.distribution = UIStackView.Distribution.fillEqually
        strip.spacing = style.spacing
        strip.frame = CGRect(x: style.horizontalInset, y: 34, width: 402 - 2 * style.horizontalInset, height: style.buttonHeight)
        controller.view.addSubview(strip)
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("iphone-keybar-decisions-\(mode).png"))
    }
}
#endif
