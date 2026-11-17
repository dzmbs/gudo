#if os(macOS)
import AppKit
import DesignSystem
import SwiftUI
import TerminalCore
import TerminalRenderer
import XCTest
@testable import App

/// Settings changed in the Settings window, by click, show at once in a terminal window beside
/// it: the terminal's font and cursor, the dim of an unfocused pane, the Option key, the theme
/// and the window's colours, the sidebar text, the tab strip and the panes' style.
@MainActor
final class SettingsEffectsTests: XCTestCase {
    private var workspaceDriver: WorkspaceDriver?
    private var settingsDriver: SettingsDriver?
    private var saved: SavedDefaults?

    override func setUp() async throws {
        saved = SavedDefaults()
        for key in [ThemePair.enabledKey, TerminalPreferences.Key.windowTheme, TerminalPreferences.Key.paneStyle,
                    TerminalPreferences.Key.fontSize, TerminalPreferences.Key.cursorStyle, TerminalPreferences.Key.cursorBlink,
                    TerminalPreferences.Key.unfocusedSplitOpacity, KeyboardSettings.optionAsMeta, TabPlacement.showsTabBarKey,
                    TerminalPreferences.Key.sidebarTextSize] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(TerminalPreferences.Default.theme, forKey: TerminalPreferences.Key.theme)
    }

    override func tearDown() async throws {
        settingsDriver?.close()
        workspaceDriver?.close()
        settingsDriver = nil
        workspaceDriver = nil
        saved?.restore()
    }

    private func open(_ pane: SettingsPane, sidebar: Bool = true) async throws -> (WorkspaceDriver, SettingsDriver) {
        let window = try await WorkspaceDriver.start(sidebar: sidebar)
        workspaceDriver = window
        let settings = try await SettingsDriver.open(SettingsNavigation(pane: pane))
        settingsDriver = settings
        return (window, settings)
    }

    private func surface(_ driver: WorkspaceDriver) throws -> TerminalSurface {
        let workspace = try driver.workspace
        let id = try XCTUnwrap(workspace.focusedPane)
        return try XCTUnwrap(workspace.pane(id)?.view.surface)
    }

    // MARK: Terminal

    func testFontSizeStepperGrowsTheTerminalsCells() async throws {
        let (window, settings) = try await open(.terminal)
        let surface = try surface(window)
        let sizeBefore = surface.fontSize
        let cellBefore = try XCTUnwrap(surface.cellSize)
        let stepper = try XCTUnwrap(settings.controls(.stepper).first, "the Size stepper")
        let frame = settings.frame(of: stepper)
        await settings.click(CGPoint(x: frame.midX, y: frame.maxY - frame.height / 4))
        await window.expect("the terminal draws one point larger") { surface.fontSize == sizeBefore + 1 }
        let cellAfter = try XCTUnwrap(surface.cellSize)
        XCTAssertGreaterThan(cellAfter.height, cellBefore.height, "taller cells")
        await settings.click(CGPoint(x: frame.midX, y: frame.minY + frame.height / 4))
        await window.expect("and back") { surface.fontSize == sizeBefore }
    }

    func testCursorStyleAndBlinkReachTheTerminal() async throws {
        let (window, settings) = try await open(.terminal)
        let surface = try surface(window)
        XCTAssertEqual(surface.appearance.cursorStyle, .block)
        await settings.choose("Bar", in: settings.controls(.popUp).first)
        await window.expect("a bar cursor") { surface.appearance.cursorStyle == .bar }
        await settings.choose("Underline", in: settings.controls(.popUp).first)
        await window.expect("an underline cursor") { surface.appearance.cursorStyle == .underline }
        XCTAssertTrue(surface.appearance.cursorBlink)
        await settings.click(settings.controls(.toggle).first)
        await window.expect("a steady cursor") { !surface.appearance.cursorBlink }
    }

    func testUnfocusedPaneOpacitySliderDimsTheOtherPane() async throws {
        let (window, settings) = try await open(.terminal)
        let before = try window.workspace.appearance.unfocusedSplitOpacity
        let slider = try XCTUnwrap(settings.controls(.slider).first)
        await settings.reveal(slider)
        let frame = settings.frame(of: slider)
        await settings.click(CGPoint(x: frame.minX + 4, y: frame.midY))
        await window.expect("panes dim further") { (try? window.workspace.appearance.unfocusedSplitOpacity).map { $0 < before - 0.2 } ?? false }
    }

    func testOptionSendsMetaReachesEveryPane() async throws {
        let (window, settings) = try await open(.keyboard)
        let workspace = try window.workspace
        let pane = try XCTUnwrap(workspace.focusedPane.flatMap { workspace.pane($0) })
        XCTAssertEqual(pane.view.optionAsMeta, OptionAsMeta.none)
        await settings.choose("Left Option", in: settings.controls(.popUp).first)
        await window.expect("left Option sends Meta") { pane.view.optionAsMeta == .left }
        await settings.choose("Both", in: settings.controls(.popUp).first)
        await window.expect("both send Meta") { pane.view.optionAsMeta == .both }
    }

    // MARK: Appearance

    /// The theme picked from its page colours the terminal, the window's chrome and its light or
    /// dark.
    func testPickingAThemeRecoloursTheTerminalAndTheWindow() async throws {
        let (window, settings) = try await open(.appearance)
        let light = "TokyoNight Day"
        let theme = ThemeCatalog.theme(named: light)
        XCTAssertTrue(theme.isLight)
        XCTAssertTrue(isDark(window.window), "starts on the default dark theme")
        await settings.click(settings.controls(.focusable).first)
        await settings.expect("the theme page opens") { settings.navigation.path == [.theme] }
        let search = try XCTUnwrap(settings.toolbarSearchField, "the themes' search")
        await settings.click(search)
        await settings.type("tokyonight day")
        await settings.pump(0.6)
        let tile = try XCTUnwrap(settings.controls(.focusable).first, "the one theme that matches")
        await settings.click(tile)
        await window.expect("the theme is chosen") { UserDefaults.standard.string(forKey: TerminalPreferences.Key.theme) == light }
        let surface = try surface(window)
        await window.expect("the terminal takes its background") { surface.appearance.background == RGB(hex: theme.bg) }
        await window.expect("the window turns light") { !self.isDark(window.window) }
    }

    func testWindowAppearanceKeepsTheWindowLightOrDark() async throws {
        let (window, settings) = try await open(.appearance)
        XCTAssertTrue(isDark(window.window), "the default theme is dark")
        await settings.click(settings.controls(.toggle)[3])
        await settings.expect("Window Appearance shows") { settings.controls(.popUp).count == 5 }
        await window.expect("off on a dark theme starts light") { !self.isDark(window.window) }
        await settings.choose("Dark", in: settings.controls(.popUp)[3])
        await window.expect("dark again") { self.isDark(window.window) }
    }

    func testSidebarTextSizeResizesTheSidebar() async throws {
        let (_, settings) = try await open(.appearance)
        await settings.choose("Large", in: settings.controls(.popUp).first)
        await settings.expect("the sidebar's text is large") { SidebarSize.shared.size == .large }
        await settings.choose("Small", in: settings.controls(.popUp).first)
        await settings.expect("and small") { SidebarSize.shared.size == .small }
    }

    func testTabBarWhenTheSidebarIsHiddenShowsOrHidesTheStrip() async throws {
        let (window, settings) = try await open(.appearance, sidebar: false)
        await window.expect("the strip is in the title bar") { self.showsStrip(window.window) }
        await settings.click(settings.controls(.toggle)[2])
        await window.expect("the strip goes") { !self.showsStrip(window.window) }
        await settings.click(settings.controls(.toggle)[2])
        await window.expect("the strip comes back") { self.showsStrip(window.window) }
    }

    /// The tab strip: a toolbar item that scrolls.
    private func showsStrip(_ window: NSWindow) -> Bool {
        (window.toolbar?.items ?? []).compactMap(\.view).contains { WindowDriver.descendant(of: $0) { $0 is NSScrollView } != nil }
    }

    /// Comfortable panes stand apart as cards; compact ones meet at a hairline.
    func testComfortablePanesSetSplitPanesApart() async throws {
        let (window, settings) = try await open(.appearance)
        window.command("d")
        await window.expect("two panes side by side") { (try? window.workspace.session.activeTab?.root.panes.count) == 2 }
        await window.settle()
        let compactGap = try gapBetweenPanes(window)
        XCTAssertLessThan(compactGap, 2, "compact panes meet at a hairline")
        let choices = settings.controls(.focusable).filter { settings.frame(of: $0).height > 60 }
        XCTAssertEqual(choices.count, 5, "two pane styles, three inactive fades")
        await settings.click(choices[1])
        await window.expect("panes are comfortable") {
            UserDefaults.standard.string(forKey: TerminalPreferences.Key.paneStyle) == TerminalPreferences.PaneStyle.comfortable.rawValue
        }
        await window.settle()
        XCTAssertGreaterThanOrEqual(try gapBetweenPanes(window), DS.Space.row, "comfortable panes stand apart")
        let card = try XCTUnwrap(settings.controls(.toggle)[4] as? NSControl)
        XCTAssertTrue(card.isEnabled, "Inset Content Card is offered for comfortable panes")
    }

    private func gapBetweenPanes(_ driver: WorkspaceDriver) throws -> CGFloat {
        let panes = try XCTUnwrap(driver.workspace.session.activeTab?.root.panes)
        let frames = panes.compactMap { driver.terminal(of: $0).map(driver.frame(of:)) }.sorted { $0.minX < $1.minX }
        XCTAssertEqual(frames.count, 2)
        guard frames.count == 2 else { return 0 }
        return frames[1].minX - frames[0].maxX
    }

    private func isDark(_ window: NSWindow) -> Bool {
        window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
#endif
