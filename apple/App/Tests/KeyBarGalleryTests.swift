#if os(iOS)
import DesignSystem
import TerminalCore
import TerminalRenderer
import UIKit
import XCTest
@testable import App

/// Renders the key bar above a terminal to PNGs, for reviewing the look:
/// `TEST_RUNNER_GUDO_CHROME_CAPTURE_DIR=<dir>`, in the dark and light default themes, at a
/// Pro iPhone's width and a small one's, in a shell (at the start and scrolled to the end) and in
/// Claude Code, and the keys panel.
@MainActor
final class KeyBarGalleryTests: XCTestCase {
    private static let themes = ["dark": TerminalPreferences.Default.theme, "light": ThemePair.resolvedDefaultLight]
    private static let screens: [(name: String, width: CGFloat, program: String?, scrolledToEnd: Bool)] = [
        ("shell", 402, nil, false),
        ("shell-end", 402, nil, true),
        ("shell-small", 375, nil, false),
        ("claude", 402, "claude", false),
    ]

    private let suite = "KeyBarGalleryTests"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: TerminalPreferences.Key.theme)
        UserDefaults.standard.removeObject(forKey: KeyBar.fullWithHardwareKeyboardKey)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testCaptureKeyBar() async throws {
        let path = try XCTUnwrap(
            ProcessInfo.processInfo.environment["GUDO_CHROME_CAPTURE_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            "set TEST_RUNNER_GUDO_CHROME_CAPTURE_DIR to capture")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // The simulator reports a hardware keyboard, which would leave only the slim pill.
        UserDefaults.standard.set(true, forKey: KeyBar.fullWithHardwareKeyboardKey)
        let storage = try XCTUnwrap(UserDefaults(suiteName: suite))
        storage.removePersistentDomain(forName: suite)

        for (appearance, theme) in Self.themes.sorted(by: { $0.key < $1.key }) {
            UserDefaults.standard.set(theme, forKey: TerminalPreferences.Key.theme)
            for screen in Self.screens {
                let window = UIWindow(windowScene: scene)
                // A phone's full height: a short window is compact height, which lays the bar out as in landscape.
                window.frame = CGRect(x: 0, y: 0, width: screen.width, height: 874)
                let controller = UIViewController()
                controller.view.backgroundColor = UIColor(KeyBarTheme.chrome.terminal.color)
                window.rootViewController = controller
                let terminal = TerminalView(surface: try TerminalSurface(terminal: Terminal(cols: 40, rows: 5) { _ in }))
                let bar = KeyBar(favourites: FavouriteKeys(defaults: storage))
                controller.view.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                    bar.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                    bar.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -16),
                ])
                bar.target = terminal
                bar.update(context: KeyBarContext(program: screen.program, title: ""))
                window.makeKeyAndVisible()
                try await Task.sleep(for: .seconds(1))
                if screen.scrolledToEnd, let strip = Self.subviews(of: bar).compactMap({ $0 as? UIScrollView })
                    .first(where: { $0.accessibilityIdentifier == "keybar-strip" })
                {
                    strip.contentOffset.x = strip.contentSize.width - strip.bounds.width
                    try await Task.sleep(for: .milliseconds(300))
                }
                let band = CGRect(x: 0, y: window.bounds.height - 96, width: screen.width, height: 96)
                let image = UIGraphicsImageRenderer(bounds: band).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("keybar-\(screen.name)-\(appearance).png"))
                window.isHidden = true
            }
            try await capturePanel(named: "keypanel-\(appearance)", scene: scene, storage: storage, into: directory)
        }
    }

    private func capturePanel(named name: String, scene: UIWindowScene, storage: UserDefaults, into directory: URL) async throws {
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(KeyBarTheme.chrome.terminal.color)
        window.rootViewController = controller
        let panel = KeyPanel(favourites: FavouriteKeys(defaults: storage))
        panel.frame = CGRect(x: 0, y: 874 - 336, width: 402, height: 336)
        panel.applyTheme()
        controller.view.addSubview(panel)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let image = UIGraphicsImageRenderer(bounds: panel.frame).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private static func subviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(subviews)
    }
}
#endif
