import SwiftUI
import Testing
@testable import DesignSystem
#if os(macOS)
import AppKit
#endif

/// The sidebar reads in one scale: a header is never smaller than the rows under it, a row under
/// the pointer stays well short of a selected one, and the attention dot stands off every row.
@MainActor
@Suite struct SidebarHierarchyTests {
    nonisolated static let themes = [TerminalTheme.ghosttyDefault] + ThemeCatalog.all
    nonisolated static let schemes: [ColorScheme?] = [nil, .light, .dark]

    #if os(macOS)
    private func height(of font: Font) -> CGFloat {
        NSHostingView(rootView: Text("Agents Hg").font(font).fixedSize()).fittingSize.height
    }

    @Test(arguments: DS.Font.SidebarSize.allCases)
    func aHeaderIsAsLargeAsTheRowsUnderIt(size: DS.Font.SidebarSize) {
        let metrics = DS.Font.sidebar(size)
        #expect(height(of: metrics.section) >= height(of: metrics.title))
        #expect(height(of: metrics.project) >= height(of: metrics.title))
    }
    #endif

    /// Under the pointer a row lights about a third as much as the selected one, so hover never
    /// reads as a second selection.
    @Test(arguments: schemes)
    func hoverIsAThirdOfSelection(scheme: ColorScheme?) {
        var failures: [String] = []
        for theme in Self.themes {
            let chrome = ChromePalette(theme: theme, scheme: scheme)
            for surface in [chrome.sidebar, chrome.base] {
                let hovered = surface.blended(with: chrome.foreground, ChromePalette.fillLevels.hover)
                let selected = surface.blended(with: chrome.foreground, ChromePalette.fillLevels.selected)
                let hoverStep = hovered.contrast(with: surface) - 1
                let selectedStep = selected.contrast(with: surface) - 1
                if hoverStep > selectedStep * 0.4 { failures.append("\(theme.name): \(hoverStep) vs \(selectedStep)") }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    @Test(arguments: schemes)
    func theAttentionMarkStandsOffEveryRow(scheme: ColorScheme?) {
        var failures: [String] = []
        for theme in Self.themes {
            let chrome = ChromePalette(theme: theme, scheme: scheme)
            for surface in [chrome.base, chrome.sidebar, chrome.raised] {
                for fill in [0, ChromePalette.fillLevels.hover, ChromePalette.fillLevels.selected, ChromePalette.fillLevels.pressed] {
                    let row = surface.blended(with: chrome.foreground, fill)
                    if chrome.attentionMark.contrast(with: row) < ChromePalette.minimumGlyphContrast {
                        failures.append("\(theme.name) \(chrome.attentionMark) on \(row)")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(5))")
    }

    /// The mark keeps the theme's own amber where it reads, not the state colour softened toward
    /// the ink, and is large enough to find at a glance.
    @Test func theAttentionMarkIsTheThemesOwnAmber() {
        let chrome = ChromePalette(theme: .ghosttyDefault)
        #expect(chrome.attentionMark.chroma > chrome.attention.chroma)
        #expect(DS.Size.attentionDot >= 8)
    }
}
