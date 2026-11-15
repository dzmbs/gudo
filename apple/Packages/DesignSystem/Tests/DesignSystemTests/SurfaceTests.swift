import SwiftUI
import Testing
@testable import DesignSystem

struct SurfaceTests {
    private let active = Surface.Context()
    private let inactive = Surface.Context(isWindowActive: false)

    @Test func everySurfaceButACompactPaneIsEdgedAndLit() {
        for surface in Surface.allCases {
            let layers = surface.layers(in: active)
            let edged = surface != .tile
            #expect((layers.innerEdgeStrength == 1) == edged, "\(surface)")
            #expect((layers.topLightStrength == 1) == edged, "\(surface)")
            #expect(layers.innerEdge == DS.Palette.edge, "\(surface)")
        }
        #expect(Surface.tile.layers(in: active).outerEdgeStrength == 0)
        #expect(Surface.selection.layers(in: active).outerEdgeStrength == 0, "a pill inside the strip needs no line around it")
    }

    @Test func panesAreOpaqueAndOnlyFloatingThingsCastAShadow() {
        for surface in [Surface.tile, .pane, .window] {
            #expect(surface.layers(in: active).fill == .solid(DS.Palette.terminal), "\(surface)")
            #expect(surface.layers(in: active).clipsContent, "\(surface)")
        }
        #expect(Surface.card.layers(in: active).fill == .glass)
        #expect(Surface.panel.layers(in: active).fill == .glass)
        #expect(Surface.selection.layers(in: active).fill == .solid(DS.Palette.selectedFill))
        let shadows = Dictionary(uniqueKeysWithValues: Surface.allCases.map { ($0, $0.layers(in: active).shadow) })
        #expect(shadows == [.tile: nil, .pane: nil, .selection: nil, .card: .float, .window: .panel, .panel: .panel])
    }

    @Test func anInactiveWindowRecedes() {
        for surface in Surface.allCases {
            let shown = surface.layers(in: active)
            let receded = surface.layers(in: inactive)
            #expect(receded.topLightStrength == 0, "\(surface)")
            #expect(receded.innerEdgeStrength == shown.innerEdgeStrength * Surface.recededEdgeStrength, "\(surface)")
            #expect(receded.outerEdgeStrength == shown.outerEdgeStrength * Surface.recededEdgeStrength, "\(surface)")
            #expect(receded.shadow != .panel, "\(surface): the lighter of the two shadows")
            #expect((receded.shadow == nil) == (shown.shadow == nil), "\(surface)")
        }
        #expect(Surface.selection.layers(in: inactive).fill == .solid(DS.Palette.hoverFill))
    }

    @Test func increasedContrastDrawsFirmFlatEdges() {
        for context in [Surface.Context(increasesContrast: true), Surface.Context(isWindowActive: false, increasesContrast: true)] {
            for surface in Surface.allCases where surface != .tile {
                let layers = surface.layers(in: context)
                #expect(layers.innerEdge == DS.Palette.border, "\(surface)")
                #expect(layers.innerEdgeStrength == 1, "\(surface)")
                #expect(layers.topLightStrength == 0, "\(surface)")
            }
        }
    }

    @Test func reducedTransparencyTurnsGlassOpaque() {
        let context = Surface.Context(reducesTransparency: true)
        #expect(Surface.card.layers(in: context).fill == .paper)
        #expect(Surface.panel.layers(in: context).fill == .paper)
        #expect(Surface.pane.layers(in: context).fill == .solid(DS.Palette.terminal))
    }

    @Test func theLightsComeFromTheTheme() {
        for theme in [TerminalTheme.ghosttyDefault, ThemeCatalog.theme(named: "iTerm2 Solarized Light")] {
            let chrome = ChromePalette(theme: theme)
            let outline = chrome.layer(.outline)
            let topLight = chrome.layer(.topLight)
            #expect(outline.alpha > 0 && outline.alpha < 1)
            #expect(topLight.alpha > 0 && topLight.alpha < 1)
            // The outline is the darker side of the theme, the light the lighter one.
            #expect(outline.color.luminance <= min(chrome.background.luminance, chrome.foreground.luminance))
            #expect(topLight.color.luminance >= max(chrome.background.luminance, chrome.foreground.luminance) - 0.001)
        }
    }
}
