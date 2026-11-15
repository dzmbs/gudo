import SwiftUI

/// What a piece of chrome is, which decides how it is built. Every surface is one recipe: its
/// fill, a hairline inside its edge, a hairline outside it, a faint light along its top (a stroke,
/// not another shadow) and at most one of the two shadows, on continuous corners. In a window
/// that is not active it recedes: softer edges, no top light, the lighter shadow, a quieter
/// selection. See docs/DESIGN.md, Surfaces.
nonisolated public enum Surface: CaseIterable, Sendable {
    /// A compact pane: the terminal's own background; the split's line is its boundary.
    case tile
    /// A comfortable pane: opaque, edged and lit, no shadow (panes are never glass).
    case pane
    /// A window over the tab (a floating pane, picture in picture): opaque, the panel shadow.
    case window
    /// Glass over content: cards, toasts, capsules, the update card, the reconnect card.
    case card
    /// Glass at the top of the stack: the palette, hand-drawn popovers and forms.
    case panel
    /// The selected tab's pill: the selected fill, edged and lit, flat.
    case selection
    /// A program mark's tile: the tile fill (inverted when selected), edged and lit, flat.
    case mark

    /// Where the surface is drawn.
    nonisolated public struct Context: Equatable, Sendable {
        public var isWindowActive: Bool
        public var increasesContrast: Bool
        public var reducesTransparency: Bool

        public init(isWindowActive: Bool = true, increasesContrast: Bool = false, reducesTransparency: Bool = false) {
            self.isWindowActive = isWindowActive
            self.increasesContrast = increasesContrast
            self.reducesTransparency = reducesTransparency
        }
    }

    /// The surface's layers, each at a strength from 0 (absent) to 1.
    nonisolated public struct Layers: Equatable, Sendable {
        public enum Fill: Equatable, Sendable {
            /// The theme's surface as Liquid Glass.
            case glass
            /// What glass stands for under Reduce Transparency: the chrome's paper, opaque.
            case paper
            case solid(ChromeStyle)
        }

        public var fill: Fill
        public var innerEdge: ChromeStyle
        public var innerEdgeStrength: Double
        public var outerEdgeStrength: Double
        public var topLightStrength: Double
        public var shadow: DS.Shadow?
        /// Panes and windows hold a terminal, which is cut to the shape; glass leaves its
        /// content alone (a focus ring may reach its edge).
        public var clipsContent: Bool
    }

    /// How far the edges of a surface in a window that is not active step back.
    public static let recededEdgeStrength = 0.5
    /// How far down the top light reaches before it has faded out.
    public static let topLightDepth = DS.Space.xxl

    public func layers(in context: Context) -> Layers {
        let edged = self != .tile
        var layers = Layers(
            fill: fill,
            innerEdge: DS.Palette.edge,
            innerEdgeStrength: edged ? 1 : 0,
            outerEdgeStrength: edged && ![.selection, .mark].contains(self) ? 1 : 0,
            topLightStrength: edged ? 1 : 0,
            shadow: shadow,
            clipsContent: [.tile, .pane, .window].contains(self))
        if !context.isWindowActive {
            layers.innerEdgeStrength *= Self.recededEdgeStrength
            layers.outerEdgeStrength *= Self.recededEdgeStrength
            layers.topLightStrength = 0
            if layers.shadow == .panel { layers.shadow = .float }
            if self == .selection { layers.fill = .solid(DS.Palette.hoverFill) }
        }
        if context.increasesContrast {
            layers.innerEdge = DS.Palette.border
            layers.innerEdgeStrength = edged ? 1 : 0
            layers.outerEdgeStrength = edged && ![.selection, .mark].contains(self) ? 1 : 0
            layers.topLightStrength = 0
        }
        if context.reducesTransparency, layers.fill == .glass { layers.fill = .paper }
        return layers
    }

    private var fill: Layers.Fill {
        switch self {
        case .tile, .pane, .window: .solid(DS.Palette.terminal)
        case .card, .panel: .glass
        case .selection: .solid(DS.Palette.selectedFill)
        case .mark: .solid(DS.Palette.tile)
        }
    }

    private var shadow: DS.Shadow? {
        switch self {
        case .tile, .pane, .selection, .mark: nil
        case .window, .panel: .panel
        case .card: .float
        }
    }
}

public extension View {
    /// Builds this view as `surface` in `shape`: its fill behind (`fill` in place of the
    /// recipe's own, such as the raised surface for a card that is not glass), its edges and top
    /// light over it, its shadow. `interactive` glass answers a press.
    func surface(_ surface: Surface, in shape: some InsettableShape, fill: ChromeStyle? = nil, interactive: Bool = false) -> some View {
        modifier(SurfaceModifier(surface: surface, shape: shape, fill: fill, interactive: interactive))
    }
}

private struct SurfaceModifier<S: InsettableShape>: ViewModifier {
    let surface: Surface
    let shape: S
    let fill: ChromeStyle?
    let interactive: Bool
    @Environment(\.chrome) private var chrome
    @Environment(\.displayScale) private var scale
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let layers = surface.layers(in: Surface.Context(
            isWindowActive: appearsActive, increasesContrast: contrast == .increased, reducesTransparency: reduceTransparency))
        let line = DS.Size.hairline(scale: scale)
        let lights: BlendMode = chrome.scheme == .dark ? .plusLighter : .normal
        filled(content, layers.fill)
            .modifier(SurfaceClip(shape: shape, clips: layers.clipsContent))
            .overlay {
                ZStack {
                    shape.inset(by: -line)
                        .strokeBorder(DS.Palette.outline, lineWidth: line)
                        .opacity(layers.outerEdgeStrength)
                    shape.strokeBorder(layers.innerEdge, lineWidth: line)
                        .blendMode(lights)
                        .opacity(layers.innerEdgeStrength)
                    shape.strokeBorder(DS.Palette.topLight, lineWidth: line)
                        .mask(alignment: .top) {
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: Surface.topLightDepth)
                        }
                        .blendMode(lights)
                        .opacity(layers.topLightStrength)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .shadow(layers.shadow ?? .float, visible: layers.shadow != nil)
    }

    @ViewBuilder private func filled(_ content: Content, _ recipe: Surface.Layers.Fill) -> some View {
        if let fill {
            content.background(fill, in: shape)
        } else {
            switch recipe {
            // Glass and its paper are one view: it turns opaque on its own under Reduce Transparency.
            case .glass, .paper: content.themedGlass(in: shape, interactive: interactive)
            case .solid(let style): content.background(style, in: shape)
            }
        }
    }
}

private struct SurfaceClip<S: Shape>: ViewModifier {
    let shape: S
    let clips: Bool

    func body(content: Content) -> some View {
        if clips { content.clipShape(shape) } else { content }
    }
}
