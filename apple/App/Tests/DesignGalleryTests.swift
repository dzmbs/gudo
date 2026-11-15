#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Renders the design system's surfaces, controls in every state, cards, toasts and the palette,
/// and the window around them, to PNGs for comparing the look before and after a design change:
/// `TEST_RUNNER_GUDO_DESIGN_GALLERY_DIR=<dir>` with the mock hosts. Each sheet is drawn in a dark
/// and a light theme, in an active and an inactive window, with and without Increase Contrast;
/// the window captures also in the compact and comfortable pane styles.
@MainActor
final class DesignGalleryTests: XCTestCase {
    private var galleryDirectory: URL!
    private var savedDefaults: [String: Any?] = [:]

    private static let themes = [("dark", TerminalPreferences.Default.theme), ("light", ThemePair.resolvedDefaultLight)]
    private static let windowStates = [("active", true), ("inactive", false)]
    private static let contrasts: [(String, ColorSchemeContrast)] = [("standard", .standard), ("increased", .increased)]
    private static let windowSize = NSSize(width: 1280, height: 800)
    private static let windowStateKeys = [
        "window.projects", "window.focusedTab", "window.focusedPane", "window.mixedTabs", "tab-touches",
    ]

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["GUDO_DESIGN_GALLERY_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        try XCTSkipIf(path == nil, "set TEST_RUNNER_GUDO_DESIGN_GALLERY_DIR to render the gallery")
        galleryDirectory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: galleryDirectory, withIntermediateDirectories: true)
        for key in [TerminalPreferences.Key.theme, TerminalPreferences.Key.paneStyle, ThemePair.enabledKey] + Self.windowStateKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        savedDefaults["sidebar"] = TabPlacement.sidebarShown
    }

    override func tearDown() async throws {
        for (key, value) in savedDefaults where key != "sidebar" {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let sidebar = savedDefaults["sidebar"] as? Bool { TabPlacement.sidebarShown = sidebar }
    }

    func testRenderComponentSheets() throws {
        for (appearance, themeName) in Self.themes {
            let theme = ThemeCatalog.theme(named: themeName)
            for (windowName, isActive) in Self.windowStates {
                for (contrastName, contrast) in Self.contrasts {
                    let sheet = GallerySheet(theme: theme)
                        .environment(\.appearsActive, isActive)
                        .environment(\._colorSchemeContrast, contrast)
                    try render(sheet, named: "components-\(appearance)-\(windowName)-\(contrastName)")
                }
            }
        }
    }

    func testRenderWindows() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        for (appearance, themeName) in Self.themes {
            UserDefaults.standard.set(false, forKey: ThemePair.enabledKey)
            UserDefaults.standard.set(themeName, forKey: TerminalPreferences.Key.theme)
            for paneStyle in TerminalPreferences.PaneStyle.allCases {
                UserDefaults.standard.set(paneStyle.rawValue, forKey: TerminalPreferences.Key.paneStyle)
                for (windowName, isActive) in Self.windowStates {
                    for (contrastName, contrast) in Self.contrasts {
                        try await captureWindow(
                            "window-\(appearance)-\(paneStyle.rawValue)-\(windowName)-\(contrastName)",
                            isActive: isActive, contrast: contrast
                        ) { model in
                            model.isSidebarShown = true
                            model.workspace?.split(.horizontal)
                            model.workspace?.split(.vertical)
                        }
                    }
                }
            }
            UserDefaults.standard.set(TerminalPreferences.PaneStyle.compact.rawValue, forKey: TerminalPreferences.Key.paneStyle)
            for (windowName, isActive) in Self.windowStates {
                try await captureWindow("tab-strip-\(appearance)-\(windowName)", isActive: isActive, contrast: .standard) { model in
                    model.isSidebarShown = false
                    for _ in 0..<4 { model.newTab() }
                    model.workspace?.split(.horizontal)
                }
            }
            try await captureWindow("palette-\(appearance)", isActive: true, contrast: .standard) { model in
                model.isSidebarShown = true
                model.isPaletteShown = true
            }
            try await captureWindow("settings-\(appearance)", isActive: true, contrast: .standard) { model in
                model.sheet = .settings
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

    private func captureWindow(
        _ name: String, isActive: Bool, contrast: ColorSchemeContrast, arrange: (WindowModel) async -> Void
    ) async throws {
        let model = WindowModel(app: .shared)
        model.start()
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let root = WindowContent(request: nil, model: model)
            .environment(AppModel.shared)
            .environment(\.appearsActive, isActive)
            .environment(\._colorSchemeContrast, contrast)
        let hosting = NSHostingController(rootView: AnyView(root))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.windowSize)
        window.orderFrontRegardless()
        defer {
            window.close()
            model.close()
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        await arrange(model)
        try await Task.sleep(for: .seconds(1.5))
        window.setContentSize(Self.windowSize)
        try await Task.sleep(for: .milliseconds(300))
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: galleryDirectory.appendingPathComponent("\(name).png"))
    }
}

/// One sheet of the design system on a theme's chrome.
private struct GallerySheet: View {
    let theme: TerminalTheme

    var body: some View {
        let chrome = ChromePalette(theme: theme)
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            GallerySection("Surfaces and text") { SurfaceRamp() }
            GallerySection("Accent and states") { AccentAndStates() }
            GallerySection("Control states") { ControlStateLadder() }
            GallerySection("Buttons") { ButtonMatrix() }
            GallerySection("Rows and fields") { RowsAndFields() }
            GallerySection("Toasts") { Toasts() }
            GallerySection("Update card") { UpdateCardSample() }
            GallerySection("Command palette") { PaletteSample() }
        }
        .padding(DS.Space.xxl)
        .frame(width: 900, alignment: .topLeading)
        .background(chrome.baseColor)
        .chromeContent()
        .environment(\.terminalTheme, theme)
        .environment(\.chrome, chrome)
        .environment(\.colorScheme, chrome.scheme)
    }
}

private struct GallerySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).font(DS.Font.section).foregroundStyle(DS.Palette.textSecondary)
            content
        }
    }
}

private struct SurfaceRamp: View {
    private let surfaces: [(String, ChromeStyle)] = [
        ("base", DS.Palette.base), ("sidebar", DS.Palette.sidebar), ("raised", DS.Palette.raised),
        ("overlay", DS.Palette.overlay), ("grouped page", DS.Palette.groupedPage), ("grouped row", DS.Palette.groupedRow),
    ]

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(surfaces, id: \.0) { name, surface in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(name).foregroundStyle(DS.Palette.text)
                    Text("Secondary").foregroundStyle(DS.Palette.textSecondary)
                    Text("Tertiary").foregroundStyle(DS.Palette.textTertiary)
                    Text("Disabled").foregroundStyle(DS.Palette.textQuaternary)
                    Hairline()
                }
                .font(DS.Font.meta)
                .padding(DS.Space.s)
                .frame(width: 132, alignment: .leading)
                .background(surface, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.hairline, lineWidth: 0.5))
            }
        }
    }
}

private struct AccentAndStates: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("Accent").foregroundStyle(DS.Palette.accent)
                Text("Selected row")
                    .foregroundStyle(DS.Palette.onSelection)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                    .background(DS.Palette.selection, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                Text("Primary")
                    .foregroundStyle(DS.Palette.onProminent)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xs)
                    .background(DS.Palette.prominent, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                Text("Done").foregroundStyle(DS.Palette.done)
                Text("Failed").foregroundStyle(DS.Palette.error)
                Text("Needs you").foregroundStyle(DS.Palette.attention)
                Text("Working").foregroundStyle(DS.Palette.working)
                Text("Info").foregroundStyle(DS.Palette.info)
            }
            HStack(spacing: DS.Space.s) {
                ForEach(AgentState.allCases, id: \.self) { state in StatusPill(state, detail: "2m") }
                CountBadge(3)
                CountBadge(12, urgent: false)
                DiffStat(added: 128, removed: 42)
                PRNumberBadge(number: 4821, kind: .open)
            }
        }
        .font(DS.Font.rowTitle)
    }
}

private struct ControlStateLadder: View {
    private let states: [(String, ControlState)] = [
        ("Rest", ControlState()), ("Hover", ControlState(isHovered: true)), ("Pressed", ControlState(isPressed: true)),
        ("Selected", ControlState(isSelected: true)), ("Disabled", ControlState(isEnabled: false)),
        ("Disabled selected", ControlState(isSelected: true, isEnabled: false)),
    ]

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(states, id: \.0) { name, state in
                Label(name, systemImage: "square.split.2x1")
                    .foregroundStyle(state.isEnabled ? DS.Palette.text : DS.Palette.text.disabled)
                    .padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.row)
                    .controlFill(state)
            }
        }
        .font(DS.Font.rowTitle)
    }
}

private struct ButtonMatrix: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.l, verticalSpacing: DS.Space.s) {
            ForEach([true, false], id: \.self) { enabled in
                GridRow {
                    Text(enabled ? "Enabled" : "Disabled").font(DS.Font.meta).foregroundStyle(DS.Palette.textSecondary)
                    Button("Find", systemImage: "magnifyingglass") {}.buttonStyle(.bar)
                    Button("Open") {}.buttonStyle(.quiet)
                    Button("Undo") {}.buttonStyle(.quietProminent)
                    Button("Forget Passwords") {}.buttonStyle(.formAction)
                    Button("Delete", role: .destructive) {}.buttonStyle(.formAction)
                    Button("Connect") {}.buttonStyle(.primaryGlass)
                    Image(systemName: "magnifyingglass").lit(enabled)
                }
                .disabled(!enabled)
            }
            GridRow {
                Text("Rows").font(DS.Font.meta).foregroundStyle(DS.Palette.textSecondary)
                Button {} label: { Text("Row").padding(DS.Space.row) }.buttonStyle(.row)
                Button {} label: { Text("Selected").padding(DS.Space.row) }.buttonStyle(.row(selected: true))
                Button {} label: { Text("Palette row").padding(DS.Space.row) }.buttonStyle(.paletteRow(selected: true))
                Button {} label: { Text("Sidebar").padding(DS.Space.row) }.buttonStyle(.sidebarRow(selected: false))
                Button {} label: { Text("Sidebar selected").padding(DS.Space.row) }.buttonStyle(.sidebarRow(selected: true))
            }
        }
        .font(DS.Font.rowTitle)
    }
}

private struct RowsAndFields: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.xxl) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("Hosts", count: 3)
                ListRow(Text("studio"), subtitle: Text("192.0.2.10"), literalSubtitle: true) {
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                } trailing: {
                    ShortcutLabel(["⌃", "⌘", "1"])
                }
                Hairline()
                ListRow(Text("build box"), subtitle: Text("Reconnecting")) {
                    StatusIndicator(.blocked)
                } trailing: {
                    KeyCap("⌘K")
                }
            }
            .frame(width: 360)
            .background(DS.Palette.sidebar, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("user@host").font(DS.Font.literal).padding(DS.Space.s).frame(width: 260, alignment: .leading)
                    .fieldSurface(isFocused: false)
                Text("user@host").font(DS.Font.literal).padding(DS.Space.s).frame(width: 260, alignment: .leading)
                    .fieldSurface(isFocused: true)
            }
        }
    }
}

private struct Toasts: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Banner(Toast("Copied", systemImage: "doc.on.doc"), dismiss: {})
            Banner(Toast("Paired with studio", systemImage: "checkmark", style: .success), dismiss: {})
            Banner(Toast("Can't reach studio", systemImage: "exclamationmark.triangle", style: .failure, action: .init("Retry") {}), dismiss: {})
        }
    }
}

private struct UpdateCardSample: View {
    @State private var prompt: UpdatePrompt = {
        let defaults = UserDefaults(suiteName: "gallery.update.\(UUID().uuidString)") ?? .standard
        let prompt = UpdatePrompt(defaults: defaults)
        prompt.found(
            UpdateOffer(version: "160", displayVersion: "0.1.6", notes: "Splits settle faster.\nChat shows why a host refused."),
            stage: .notDownloaded, userInitiated: true, reply: { _ in })
        return prompt
    }()

    var body: some View {
        UpdateCard(prompt: prompt).frame(width: 300)
    }
}

private struct PaletteSample: View {
    @State private var isPresented = true

    var body: some View {
        CommandPalette(isPresented: $isPresented, commands: [
            PaletteCommand(id: "new", title: "New Tab", section: "Tabs", systemImage: "plus", shortcut: ["⌘", "T"]) {},
            PaletteCommand(id: "split", title: "Split Right", section: "Panes", systemImage: "square.split.2x1", shortcut: ["⌘", "D"]) {},
            PaletteCommand(id: "agent", title: "claude", subtitle: "studio · gudo", section: "Agents", state: .blocked, badge: "Needs You") {},
            PaletteCommand(id: "host", title: "Connect to build box", section: "Hosts", systemImage: "server.rack") {},
        ])
        .frame(width: DS.Size.paletteWidth, height: 300)
        .floatingPanel(elevated: true)
    }
}
#endif
