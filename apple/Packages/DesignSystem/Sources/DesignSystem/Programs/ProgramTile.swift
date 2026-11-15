import SwiftUI

/// How program tiles take colour (Settings › Appearance › Program Marks).
nonisolated public enum ProgramTileTint: String, CaseIterable, Identifiable, Sendable {
    /// A neutral tile; logos in their own colours, symbols in the muted ink.
    case original
    /// A neutral tile; symbols and one-colour marks in the full ink.
    case monochrome
    /// The accent's tint under the mark; symbols and one-colour marks in the accent. A selected
    /// tile inverts as in the others, so colour logos keep a neutral ground.
    case accent

    public static let key = "program-mark-tint"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original"
        case .monochrome: "Monochrome"
        case .accent: "Accent"
        }
    }
}

/// A program's mark on a small tile from the theme: a neutral container fill, a hairline edge
/// and a faint light along its top, continuous corners. The mark itself is drawn as it always
/// is. A selected row inverts the tile (a light tile and a dark mark on a dark theme, the
/// reverse on a light one). An agent's quiet states are a dot cut into the tile's corner; the
/// ones that need you are a `StatePill` beside the title instead.
public struct ProgramTile: View {
    /// The tile leading sidebar rows and tab chips: the slot every row's title aligns after.
    public static let rowSize = ProgramMark.rowSlot

    let identity: ProgramIdentity
    var size: CGFloat
    var isSelected: Bool
    var state: AgentState?

    public init(_ identity: ProgramIdentity, size: CGFloat = ProgramTile.rowSize, isSelected: Bool = false, state: AgentState? = nil) {
        self.identity = identity
        self.size = size
        self.isSelected = isSelected
        self.state = state
    }

    public var body: some View {
        TileArtwork(size: size, isSelected: isSelected) { glyphSize, isMuted in
            ProgramMark(identity, size: glyphSize, isMuted: isMuted)
        }
        .stateDot(state, tileSize: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.flatMap { $0.statusMark == .dot && $0 != .idle ? "\(identity.displayName), \($0.title)" : nil } ?? identity.displayName)
        .accessibilityIdentifier("program-mark-\(identity.id)")
    }
}

/// Any artwork on a program tile: a program's mark, a page's icon.
public struct TileArtwork<Artwork: View>: View {
    let size: CGFloat
    let isSelected: Bool
    let artwork: (_ glyphSize: CGFloat, _ isMuted: Bool) -> Artwork
    @AppStorage(ProgramTileTint.key) private var tint = ProgramTileTint.original
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat, isSelected: Bool = false, @ViewBuilder artwork: @escaping (_ glyphSize: CGFloat, _ isMuted: Bool) -> Artwork) {
        self.size = size
        self.isSelected = isSelected
        self.artwork = artwork
    }

    /// The mark's share of its tile, leaving room for the edge and the rounding.
    public static var glyphShare: CGFloat { 0.72 }

    public var body: some View {
        let shape = RoundedRectangle.rounded(radius)
        artwork((size * Self.glyphShare).rounded(), tint == .original && !isSelected)
            .foregroundStyle(glyph)
            // On an inverted tile a logo takes the variant made for the tile's own lightness.
            .environment(\.colorScheme, isSelected ? colorScheme.inverted : colorScheme)
            .frame(width: size, height: size)
            .surface(.mark, in: shape, fill: fill)
            .animation(DS.Motion.micro, value: isSelected)
    }

    /// Concentric with the row's own corners at the sizes rows use; a step up for large tiles.
    private var radius: CGFloat { size > 20 ? DS.Radius.field : DS.Radius.chip }

    private var fill: ChromeStyle {
        switch (tint, isSelected) {
        case (_, true): DS.Palette.text
        case (.accent, false): DS.Palette.accentDim
        case (_, false): DS.Palette.tile
        }
    }

    private var glyph: ChromeStyle {
        switch (tint, isSelected) {
        case (_, true): DS.Palette.base
        case (.accent, false): DS.Palette.accent
        case (_, false): DS.Palette.text
        }
    }
}

private extension ColorScheme {
    var inverted: ColorScheme { self == .dark ? .light : .dark }
}
