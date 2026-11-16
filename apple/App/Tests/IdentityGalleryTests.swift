#if os(macOS)
import AppKit
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import XCTest
@testable import App

/// Renders program marks and agent states where the window shows them (sidebar rows, tab strip
/// chips, pane headers) to PNGs: every state, a selected and an unselected tab, dark and light,
/// `TEST_RUNNER_GUDO_IDENTITY_GALLERY_DIR=<dir>` with the mock hosts.
@MainActor
final class IdentityGalleryTests: XCTestCase {
    private var galleryDirectory: URL!
    private var savedDefaults: [String: Any?] = [:]

    private static let windowStateKeys = ["window.projects", "window.focusedTab", "window.focusedPane", "window.mixedTabs", "tab-touches"]
    private static let size = NSSize(width: 1280, height: 640)
    private static let themes = [("dark", TerminalPreferences.Default.theme), ("light", ThemePair.resolvedDefaultLight)]

    /// One tab per state and program; the first splits into a pane per state for its headers.
    private static let tabs: [(name: String, program: String, state: AgentState?)] = [
        ("~/projects/gudo", "claude", .working),
        ("review", "codex", .blocked),
        ("tests", "claude", .working),
        ("refactor", "pi", .done),
        ("ci", "opencode", .error),
        ("notes", "amp", nil),
        ("~", "-zsh", nil),
    ]
    private static let splitPanes: [(program: String, state: AgentState?)] = [("codex", .blocked), ("pi", .done), ("amp", .error)]

    override func setUp() async throws {
        try XCTSkipIf(!LaunchOptions.mock, "needs the mock hosts (TEST_RUNNER_GUDO_MOCK=1)")
        let path = ProcessInfo.processInfo.environment["GUDO_IDENTITY_GALLERY_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        try XCTSkipIf(path == nil, "set TEST_RUNNER_GUDO_IDENTITY_GALLERY_DIR to render the gallery")
        galleryDirectory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        try FileManager.default.createDirectory(at: galleryDirectory, withIntermediateDirectories: true)
        for key in [TerminalPreferences.Key.theme, ThemePair.enabledKey, ProgramTileTint.key] + Self.windowStateKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        savedDefaults["sidebar"] = TabPlacement.sidebarShown
    }

    override func tearDown() async throws {
        MockPaneStatus.fixture = nil
        for (key, value) in savedDefaults where key != "sidebar" {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let sidebar = savedDefaults["sidebar"] as? Bool { TabPlacement.sidebarShown = sidebar }
    }

    func testRenderIdentityAndStatus() async throws {
        for (appearance, theme) in Self.themes {
            UserDefaults.standard.set(false, forKey: ThemePair.enabledKey)
            UserDefaults.standard.set(theme, forKey: TerminalPreferences.Key.theme)
            for (placement, showsSidebar) in [("sidebar", true), ("tab-strip", false)] {
                for (selection, selectedIndex) in [("selected-agent", 0), ("selected-idle", 5)] {
                    try await capture("\(placement)-\(appearance)-\(selection)") { model in
                        model.isSidebarShown = showsSidebar
                        Self.arrange(model, selecting: selectedIndex)
                    }
                }
            }
        }
    }

    /// Every tint, each program's tile at rest and selected, with every state, on the sidebar.
    func testRenderTileSheets() throws {
        for (appearance, themeName) in Self.themes {
            let theme = ThemeCatalog.theme(named: themeName)
            for tint in ProgramTileTint.allCases {
                UserDefaults.standard.set(tint.rawValue, forKey: ProgramTileTint.key)
                let renderer = ImageRenderer(content: TileSheet(theme: theme))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                let tiff = try XCTUnwrap(image.tiffRepresentation)
                let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: galleryDirectory.appendingPathComponent("tiles-\(appearance)-\(tint.rawValue).png"))
            }
        }
    }

    /// Every program the catalog knows, as its row tile, at rest and selected.
    func testRenderProgramMarks() throws {
        for (appearance, themeName) in Self.themes {
            let renderer = ImageRenderer(content: ProgramSheet(theme: ThemeCatalog.theme(named: themeName)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: galleryDirectory.appendingPathComponent("programs-\(appearance).png"))
        }
    }

    private static func arrange(_ model: WindowModel, selecting selectedIndex: Int) {
        guard let workspace = model.workspace else { return }
        // The mock host keeps its tabs across windows: start every capture from these alone.
        let earlierTabs = workspace.session.tabs.map(\.id)
        var fixture: [String: (program: String, state: AgentState?)] = [:]
        for tab in tabs {
            workspace.apply(.newTab)
            guard let id = workspace.session.activeTabId, let pane = workspace.focusedPane else { continue }
            workspace.apply(.rename(id, tab.name))
            fixture[pane.description] = (tab.program, tab.state)
        }
        for id in earlierTabs { workspace.apply(.closeTab(id)) }
        if let first = workspace.session.tabs.first {
            workspace.selectTab(first.id)
            for (index, split) in splitPanes.enumerated() {
                guard let pane = workspace.focusedPane else { break }
                workspace.apply(.split(pane, index.isMultiple(of: 2) ? .horizontal : .vertical))
                if let added = workspace.focusedPane { fixture[added.description] = (split.program, split.state) }
            }
            workspace.apply(.focus(first.focused))
        }
        MockPaneStatus.fixture = fixture
        let selected = workspace.session.tabs[min(selectedIndex, workspace.session.tabs.count - 1)]
        workspace.selectTab(selected.id)
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func capture(_ name: String, _ arrange: (WindowModel) async -> Void) async throws {
        let model = WindowModel(app: .shared)
        model.start()
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingController(rootView: AnyView(WindowContent(request: nil, model: model).environment(AppModel.shared)))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.size)
        window.orderFrontRegardless()
        defer {
            window.close()
            model.close()
        }
        for _ in 0..<50 where model.workspace?.focusedPane == nil { try await Task.sleep(for: .milliseconds(100)) }
        await arrange(model)
        try await Task.sleep(for: .seconds(1.5))
        window.setContentSize(Self.size)
        try await Task.sleep(for: .milliseconds(300))
        let view = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: galleryDirectory.appendingPathComponent("\(name).png"))
    }
}

private struct ProgramSheet: View {
    let theme: TerminalTheme
    private let columns = 4

    var body: some View {
        let chrome = ChromePalette(theme: theme)
        let entries = ProgramCatalog.entries
        let rows = stride(from: 0, to: entries.count, by: columns).map { Array(entries[$0..<min($0 + columns, entries.count)]) }
        Grid(alignment: .leading, horizontalSpacing: DS.Space.xl, verticalSpacing: DS.Space.s) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row, id: \.id) { identity in
                        HStack(spacing: DS.Space.s) {
                            ProgramTile(identity)
                            ProgramTile(identity, isSelected: true)
                                .padding(DS.Space.xxs)
                                .background(DS.Palette.selectedFill, in: .rounded(DS.Radius.control))
                            Text(identity.displayName).font(DS.Font.meta)
                        }
                        .frame(width: 190, alignment: .leading)
                    }
                }
            }
        }
        .padding(DS.Space.l)
        .background(chrome.color(.sidebar))
        .foregroundStyle(DS.Palette.text)
        .environment(\.terminalTheme, theme)
        .environment(\.chrome, chrome)
        .environment(\.colorScheme, chrome.scheme)
    }
}

private struct TileSheet: View {
    let theme: TerminalTheme
    private let programs = ["claude", "codex", "pi", "opencode", "amp", "nvim", "git", "zsh"]
    private let states: [AgentState?] = [nil, .idle, .working, .done, .blocked, .error]

    var body: some View {
        let chrome = ChromePalette(theme: theme)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(programs, id: \.self) { name in
                let identity = ProgramCatalog.identity(process: name)
                HStack(spacing: DS.Space.l) {
                    Text(identity.displayName).font(DS.Font.meta).frame(width: 90, alignment: .leading)
                    ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                        HStack(spacing: DS.Space.xs) {
                            ProgramTile(identity, size: 17, state: state)
                            ProgramTile(identity, size: 17, isSelected: true, state: state)
                                .padding(DS.Space.xxs)
                                .background(DS.Palette.selectedFill, in: .rounded(DS.Radius.control))
                            if let state { StatePill(state) }
                        }
                        .frame(width: 130, alignment: .leading)
                    }
                }
            }
        }
        .padding(DS.Space.l)
        .background(chrome.color(.sidebar))
        .foregroundStyle(DS.Palette.text)
        .environment(\.terminalTheme, theme)
        .environment(\.chrome, chrome)
        .environment(\.colorScheme, chrome.scheme)
    }
}
#endif
