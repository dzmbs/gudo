import DesignSystem
import SwiftUI
import XCTest
@testable import App
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Every surface stands on the user's terminal theme: the window's toolbar band, the Settings
/// window's title bar, a pane while its host connects, the empty states and a canvas before its
/// page loads. Each is drawn in-process under a navy dark, a light and a high-contrast theme and
/// its background pixels compared with the palette. `THEME_SHOTS_DIR` keeps the pictures.
@MainActor
final class ThemeConsistencyTests: XCTestCase {
    static let themes = ["Atelier Sulphurpool", "TokyoNight Day", "GitHub Dark High Contrast"]
    /// Per channel, out of 255: window server compositing and colour matching stay within it.
    nonisolated static let tolerance = 6

    private let environment = ProcessInfo.processInfo.environment

    override func setUp() async throws {
        try XCTSkipUnless(LaunchOptions.mock, "renders the mock workspace")
    }

    override func tearDown() async throws {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[TerminalPreferences.Key.theme] = nil
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        #if os(macOS)
        NSApp.appearance = nil
        #endif
    }

    private func use(_ theme: String) -> ChromePalette {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[TerminalPreferences.Key.theme] = theme
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        return ChromePalette(theme: ThemeCatalog.theme(named: theme))
    }

    private func pump(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Surfaces

    func testConnectingPaneKeepsTheThemeBackground() async throws {
        for name in Self.themes {
            let palette = use(name)
            let theme = ThemeCatalog.theme(named: name)
            let picture = try await render("connecting", theme: name, size: CGSize(width: 640, height: 400)) {
                theme.background
                    .overlay(alignment: .topLeading) {
                        Text("~/src/app $ cargo build").font(.system(.body, design: .monospaced)).foregroundStyle(theme.foreground).padding(12)
                    }
                    .connectionOverlay(.connecting(phase: nil), hostName: "studio", onRetry: {}, onDisconnect: {})
            } settle: { await self.pump(3.2) }
            try picture.expect(palette.base, at: CGPoint(x: 320, y: 300), "\(name): a dimmed pane fades toward the theme's background, not grey")
            try picture.expect(palette.base, at: CGPoint(x: 40, y: 360), "\(name): connecting")
        }
    }

    func testEmptyStatesAndCanvasPlaceholder() async throws {
        for name in Self.themes {
            let palette = use(name)
            let picture = try await render("empty", theme: name, size: CGSize(width: 900, height: 480)) {
                HStack(spacing: 0) {
                    EmptyState("No Agents Yet", systemImage: "tray", message: "Start an agent on a host.") {}
                    EmptyState("No Host", systemImage: "server.rack", message: "Connect a host to browse its files.") {}
                }
                .chromeBackground(DS.Palette.base)
                .chromeContent()
            } settle: { await self.pump(1.2) }
            try picture.expect(palette.base, at: CGPoint(x: 40, y: 440), "\(name): empty state")
            try picture.expect(palette.base, at: CGPoint(x: 860, y: 440), "\(name): empty state")
        }
    }

    #if os(macOS)
    func testSettingsWindowIsThemedUpToTheTitleBar() async throws {
        for name in Self.themes {
            let palette = use(name)
            let picture = try await render("settings", theme: name, size: CGSize(width: 820, height: 560), sceneWindow: true) {
                SettingsView(navigation: SettingsNavigation(pane: .privacy))
            } settle: { await self.pump(1.5) }
            try picture.expect(palette.groupedPage, at: CGPoint(x: 790, y: 12), "\(name): the title bar over the form")
            try picture.expect(palette.sidebar, at: CGPoint(x: 200, y: 12), "\(name): the title bar over the sidebar")
            try picture.expect(palette.groupedPage, at: CGPoint(x: 236, y: 300), "\(name): the form's page")
            try picture.expect(palette.sidebar, at: CGPoint(x: 12, y: 540), "\(name): the sidebar")
        }
    }

    func testMainWindowToolbarAndPanes() async throws {
        for name in Self.themes {
            let palette = use(name)
            let model = WindowModel(app: .shared)
            model.start()
            defer { model.close() }
            let picture = try await render("main", theme: name, size: CGSize(width: 1180, height: 760), sceneWindow: true) {
                WindowContent(request: nil, model: model).environment(AppModel.shared)
            } settle: {
                for _ in 0..<50 where model.workspace?.focusedPane == nil { await self.pump(0.1) }
                model.isSidebarShown = true
                await self.pump(1.5)
            }
            try picture.expect(palette.base, at: CGPoint(x: 760, y: 8), "\(name): the toolbar band over the panes")
            try picture.expect(palette.sidebar, at: CGPoint(x: 200, y: 740), "\(name): the sidebar")
        }
    }
    #else
    func testSettingsSheetIsThemedUpToTheNavigationBar() async throws {
        for name in Self.themes {
            let palette = use(name)
            let picture = try await render("settings", theme: name, size: CGSize(width: 390, height: 720)) {
                SettingsView().chromeSheetBackground()
            } settle: { await self.pump(1.5) }
            try picture.expect(palette.groupedPage, at: CGPoint(x: 120, y: 6), "\(name): the navigation bar")
            try picture.expect(palette.groupedPage, at: CGPoint(x: 6, y: 300), "\(name): the form's page")
            try picture.expect(palette.groupedPage, at: CGPoint(x: 6, y: 712), "\(name): the form's page")
        }
    }
    #endif

    // MARK: Rendering

    /// What a surface looks like on screen, in sRGB, addressed in points from the top left.
    struct Picture {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        func color(at point: CGPoint) -> ThemeColor {
            let x = min(width - 1, Int(point.x * scale)), y = min(height - 1, Int(point.y * scale))
            let offset = (y * width + x) * 4
            return ThemeColor(Double(pixels[offset]) / 255, Double(pixels[offset + 1]) / 255, Double(pixels[offset + 2]) / 255)
        }

        func expect(_ expected: ThemeColor, at point: CGPoint, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let actual = color(at: point)
            let difference = Int((max(abs(actual.r - expected.r), abs(actual.g - expected.g), abs(actual.b - expected.b)) * 255).rounded())
            XCTAssertLessThanOrEqual(
                difference, ThemeConsistencyTests.tolerance,
                "\(message): \(actual.hex) at \(point), the theme says \(expected.hex)", file: file, line: line)
        }
    }

    private func render(
        _ surface: String, theme: String, size: CGSize, sceneWindow: Bool = false,
        @ViewBuilder _ content: () -> some View, settle: () async -> Void
    ) async throws -> Picture {
        let root = ThemedRoot { content() }
        #if os(macOS)
        let window = OffscreenWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: sceneWindow ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if sceneWindow { window.toolbarStyle = .unified }
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = controller
        window.setFrame(NSRect(x: -30000, y: -30000, width: size.width, height: size.height), display: false)
        window.orderFrontRegardless()
        defer { window.close() }
        await settle()
        let image = try XCTUnwrap(Self.windowImage(window.windowNumber), "the window server's picture of the window")
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        defer { window.isHidden = true }
        await settle()
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let image = try XCTUnwrap(rendered.cgImage)
        #endif
        let picture = try Self.picture(of: image, pointWidth: size.width)
        try keep(image, name: "\(surface)-\(theme)")
        return picture
    }

    private static func picture(of image: CGImage, pointWidth: CGFloat) throws -> Picture {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return Picture(pixels: pixels, width: width, height: height, scale: CGFloat(width) / pointWidth)
    }

    private func keep(_ image: CGImage, name: String) throws {
        guard let directory = environment["THEME_SHOTS_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(macOS)
        let platform = "mac"
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #else
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let data = UIImage(cgImage: image).pngData()
        #endif
        let file = folder.appendingPathComponent("\(platform)-\(name.replacingOccurrences(of: " ", with: "-")).png")
        try data?.write(to: file)
    }

    #if os(macOS)
    /// A window that never reaches the screen: far off it, never ordered in front of another app.
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        override var canBecomeKey: Bool { true }
    }

    /// `CGWindowListCreateImage`, looked up at run time: the SDK marks it unavailable, and it is
    /// the one capture of an app's own window that asks no permission.
    private static func windowImage(_ number: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        return create(.null, 1 << 3, UInt32(number), (1 << 0) | (1 << 3))?.takeRetainedValue()
    }
    #endif
}
