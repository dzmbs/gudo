#if os(iOS)
import DesignSystem
import SwiftUI
import UIKit
import XCTest
@testable import App

/// Renders the iPhone's tab list (the grouped cards per project) to PNGs, for reviewing the
/// look: `TEST_RUNNER_GUDO_CHROME_CAPTURE_DIR=<dir>` with the mock hosts.
@MainActor
final class PhoneTabListGalleryTests: XCTestCase {
    func testCaptureTabList() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["GUDO_CHROME_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            "set TEST_RUNNER_GUDO_CHROME_CAPTURE_DIR to capture")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = WindowModel(app: .shared)
        model.start()
        defer {
            MockPaneStatus.fixture = nil
            model.close()
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        await SidebarFixture.arrangeProjects(model)
        let workspace = try XCTUnwrap(model.workspace)

        for (name, size) in [("phone", DynamicTypeSize.large), ("phone-xxxl", .xxxLarge)] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = UIHostingController(rootView: TabOverview(workspace: workspace)
                .environment(model)
                .environment(AppModel.shared)
                .dynamicTypeSize(size))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(1.5))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
            window.isHidden = true
        }
    }
}
#endif
