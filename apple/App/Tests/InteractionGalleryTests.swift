#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import XCTest
@testable import App

/// Renders the popovers, the palette, the switchers, toasts and the Settings panes in a dark and
/// a light theme and under each accessibility setting, for comparing interaction polish before
/// and after a change: `TEST_RUNNER_GUDO_INTERACTION_GALLERY_DIR=<dir>`.
@MainActor
final class InteractionGalleryTests: XCTestCase {
    private var galleryDirectory: URL!

    private static let themes = [("dark", TerminalPreferences.Default.theme), ("light", ThemePair.resolvedDefaultLight)]

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["GUDO_INTERACTION_GALLERY_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        try XCTSkipIf(path == nil, "set TEST_RUNNER_GUDO_INTERACTION_GALLERY_DIR to render the gallery")
        galleryDirectory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: galleryDirectory, withIntermediateDirectories: true)
    }

    func testRenderPopovers() throws {
        for (appearance, themeName) in Self.themes {
            let theme = ThemeCatalog.theme(named: themeName)
            for setting in GalleryAccessibility.allCases {
                try render(InteractionSheet(theme: theme).galleryAccessibility(setting), named: "popovers-\(appearance)-\(setting.rawValue)")
            }
        }
    }

    func testRenderToasts() throws {
        for (appearance, themeName) in Self.themes {
            let theme = ThemeCatalog.theme(named: themeName)
            for setting in GalleryAccessibility.allCases {
                try render(ToastSheet(theme: theme).galleryAccessibility(setting), named: "toasts-\(appearance)-\(setting.rawValue)")
            }
        }
    }

    func testRenderToastPlacement() throws {
        for (appearance, themeName) in Self.themes {
            let theme = ThemeCatalog.theme(named: themeName)
            try render(ToastPlacementSheet(theme: theme), named: "toast-placement-\(appearance)")
        }
    }

    func testRenderSettings() async throws {
        for (appearance, themeName) in Self.themes {
            let saved = UserDefaults.standard.object(forKey: TerminalPreferences.Key.theme)
            let savedPair = UserDefaults.standard.object(forKey: ThemePair.enabledKey)
            UserDefaults.standard.set(false, forKey: ThemePair.enabledKey)
            UserDefaults.standard.set(themeName, forKey: TerminalPreferences.Key.theme)
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: TerminalPreferences.Key.theme) } else { UserDefaults.standard.removeObject(forKey: TerminalPreferences.Key.theme) }
                if let savedPair { UserDefaults.standard.set(savedPair, forKey: ThemePair.enabledKey) } else { UserDefaults.standard.removeObject(forKey: ThemePair.enabledKey) }
            }
            for pane in [SettingsPane.appearance, .terminal] {
                for setting in [GalleryAccessibility.standard, .increasedContrast] {
                    try await captureWindow(
                        SettingsView(navigation: SettingsNavigation(pane: pane)).galleryAccessibility(setting),
                        size: NSSize(width: 720, height: 900), named: "settings-\(pane.rawValue)-\(appearance)-\(setting.rawValue)")
                }
            }
        }
    }

    private func render(_ content: some View, named name: String) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, name)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: galleryDirectory.appendingPathComponent("\(name).png"))
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func captureWindow(_ content: some View, size: NSSize, named name: String) async throws {
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingController(rootView: AnyView(content.environment(AppModel.shared)))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: galleryDirectory.appendingPathComponent("\(name).png"))
    }
}

/// The accessibility settings a gallery sheet is drawn under, one at a time.
private enum GalleryAccessibility: String, CaseIterable {
    case standard, increasedContrast = "increased-contrast", reduceTransparency = "reduce-transparency"
    case differentiateWithoutColor = "differentiate-without-color", reduceMotion = "reduce-motion"
}

private extension View {
    func galleryAccessibility(_ setting: GalleryAccessibility) -> some View {
        environment(\._colorSchemeContrast, setting == .increasedContrast ? .increased : .standard)
            .environment(\._accessibilityReduceTransparency, setting == .reduceTransparency)
            .environment(\._accessibilityDifferentiateWithoutColor, setting == .differentiateWithoutColor)
            .environment(\._accessibilityReduceMotion, setting == .reduceMotion)
    }
}

private struct GalleryTheme<Content: View>: View {
    let theme: TerminalTheme
    @ViewBuilder let content: Content

    var body: some View {
        let chrome = ChromePalette(theme: theme)
        content
            .padding(DS.Space.xxl)
            .background(chrome.baseColor)
            .chromeContent()
            .environment(\.terminalTheme, theme)
            .environment(\.chrome, chrome)
            .environment(\.colorScheme, chrome.scheme)
    }
}

private struct InteractionSheet: View {
    let theme: TerminalTheme

    var body: some View {
        GalleryTheme(theme: theme) {
            HStack(alignment: .top, spacing: DS.Space.xxl) {
                GalleryPalette()
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    GalleryPopover { GalleryHostSwitcher() }
                    GalleryPopover { GalleryPeopleSwitcher() }
                }
            }
        }
    }
}

/// A popover's own surface around a switcher, as the system draws it.
private struct GalleryPopover<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(DS.Palette.raised, in: .rounded(DS.Radius.pane))
            .hairlineBorder(RoundedRectangle.rounded(DS.Radius.pane), style: DS.Palette.separator)
    }
}

private struct GalleryPalette: View {
    @State private var isPresented = true

    var body: some View {
        CommandPalette(isPresented: $isPresented, commands: [
            PaletteCommand(id: "new", title: "New Tab", section: "Tabs", systemImage: "plus", shortcut: ["⌘", "T"]) {},
            PaletteCommand(id: "split", title: "Split Right", section: "Panes", systemImage: "square.split.2x1", shortcut: ["⌘", "D"]) {},
            PaletteCommand(id: "agent", title: "claude", subtitle: "studio · gudo", section: "Agents", state: .blocked, badge: "Needs You") {},
            PaletteCommand(id: "done", title: "codex", subtitle: "build box · site", section: "Agents", state: .done) {},
            PaletteCommand(id: "host", title: "Connect to build box", section: "Hosts", systemImage: "server.rack") {},
        ])
        .frame(width: DS.Size.paletteWidth)
    }
}

private struct GalleryHostSwitcher: View {
    var body: some View {
        HostSwitcher(
            hosts: [
                HostSwitcherHost(id: "studio", name: "studio", systemImage: "desktopcomputer", address: "dev@studio", isCurrent: true, shortcut: 1),
                HostSwitcherHost(id: "build", name: "build box", systemImage: "server.rack", detail: "2 need you", needsYou: true, shortcut: 2),
                HostSwitcherHost(id: "pi", name: "pi", systemImage: "cpu", detail: "Offline", link: .down, shortcut: 3),
            ],
            commands: [
                HostSwitcherCommand(id: "tab", title: "New Tab", systemImage: "plus", shortcut: ["⌘", "T"]) {},
                HostSwitcherCommand(id: "ssh", group: 1, title: "Connect via SSH…", systemImage: "terminal", shortcut: ["⇧", "⌘", "K"]) {},
            ],
            onSelect: { _ in }, onCreate: { _ in }, focusesFilter: false, onDismiss: {})
    }
}

private struct GalleryPeopleSwitcher: View {
    var body: some View {
        PeopleSwitcher(
            people: [
                PeopleSwitcherPerson(id: "me", avatar: Participant(id: "me", name: "Dana", hue: 4), name: "Dana", isMe: true),
                PeopleSwitcherPerson(id: "kim", avatar: Participant(id: "kim", name: "Kim", hue: 2), name: "Kim", detail: "Typing in Claude Code", isFollowed: true),
                PeopleSwitcherPerson(id: "lee", avatar: Participant(id: "lee", name: "Lee", hue: 5), name: "Lee", detail: "Away"),
            ],
            commands: [HostSwitcherCommand(id: "share", title: "Share Session…", systemImage: "person.badge.plus") {}],
            onFollow: { _ in }, onDismiss: {})
    }
}

/// A window's content area with a toast where the toast host puts it.
private struct ToastPlacementSheet: View {
    let theme: TerminalTheme
    @State private var center: ToastCenter = {
        let center = ToastCenter()
        center.show(Toast("Copied", systemImage: "doc.on.doc"))
        return center
    }()

    var body: some View {
        GalleryTheme(theme: theme) {
            Rectangle()
                .fill(DS.Palette.terminal)
                .frame(width: 640, height: 280)
                .toastHost(center)
                .hairlineBorder(Rectangle(), style: DS.Palette.separator)
        }
    }
}

private struct ToastSheet: View {
    let theme: TerminalTheme

    var body: some View {
        GalleryTheme(theme: theme) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Banner(Toast("Copied", systemImage: "doc.on.doc"), dismiss: {})
                Banner(Toast("Paired with studio", systemImage: "checkmark", style: .success), dismiss: {})
                Banner(Toast("Can't reach studio", systemImage: "exclamationmark.triangle", style: .failure, action: .init("Retry") {}), dismiss: {})
                Banner(Toast("Saved", style: .success), dismiss: {})
                Banner(Toast("Could not save the file", style: .failure), dismiss: {})
            }
        }
    }
}
#endif
