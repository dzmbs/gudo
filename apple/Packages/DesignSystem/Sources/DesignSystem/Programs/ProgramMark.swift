import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// logo where one ships, unaltered in its own colours or drawn in the text colour where the owner
/// allows a monochrome version (the owner's dark-background variant, where it publishes one,
/// follows the scheme through the asset's dark appearance); otherwise its kind's SF Symbol in the
/// inherited foreground style.
/// A new program cross-fades in place, so the row never jumps. Its accessibility label is the
/// program's display name.
public struct ProgramMark: View {
    /// 16 pt on the Mac; 18 on iPad and iPhone, a step up with their larger titles).
    #if os(macOS)
    public static let rowSlot: CGFloat = 16
    public static let rowSize: CGFloat = 14
    #else
    public static let rowSlot: CGFloat = 18
    public static let rowSize: CGFloat = 16
    #endif
    /// and one-colour logos draw at 0.6 of the inherited foreground. Colour logos stay as their
    /// owners publish them.
    public static let mutedOpacity: Double = 0.6

    let identity: ProgramIdentity
    var size: CGFloat

    public init(_ identity: ProgramIdentity, size: CGFloat = ProgramMark.rowSize) {
        self.identity = identity
        self.size = size
    }

    public var body: some View {
        ZStack {
            art
                .id(identity.id)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
        }
        .frame(width: size, height: size)
        .animation(DS.Motion.indicator, value: identity.id)
        .accessibilityElement()
        .accessibilityLabel(identity.displayName)
        .accessibilityIdentifier("program-mark-\(identity.id)")
    }

    @ViewBuilder private var art: some View {
        if let logo = identity.logo {
            Image(logo.asset, bundle: .module)
                .renderingMode(logo.template ? .template : .original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .opacity(logo.template ? Self.mutedOpacity : 1)
        } else {
            Image(systemName: identity.symbol)
                .font(.system(size: size * 0.82, weight: .medium))
                .frame(width: size, height: size)
                .opacity(Self.mutedOpacity)
        }
    }
}

/// The bundle's logo images, for tests.
nonisolated enum ProgramLogoImage {
    static func exists(_ asset: String) -> Bool {
        #if canImport(UIKit)
        UIImage(named: asset, in: .module, with: nil) != nil
        #else
        Bundle.module.image(forResource: asset) != nil
        #endif
    }
}

extension ProgramIdentity {
    /// The mark as a plain image, for system menus and labels that take one. Menus draw an asset
    /// at its artwork's own size, so logos are rendered here at a symbol's size (18 pt) to sit
    /// level with the SF Symbols beside them.
    public var image: Image {
        guard let logo else { return Image(systemName: symbol) }
        return ProgramLogoImage.menuImage(logo) ?? Image(logo.asset, bundle: .module)
    }
}

extension ProgramLogoImage {
    static let menuSide: CGFloat = 18
    @MainActor private static var cache: [ProgramIdentity.Logo: Image] = [:]

    @MainActor static func menuImage(_ logo: ProgramIdentity.Logo) -> Image? {
        if let cached = cache[logo] { return cached }
        let side = menuSide
        #if canImport(UIKit)
        // Light and dark renders in one asset, so a set with the owner's dark variant (Codex,
        // Copilot, Deno, Go, Rust) still follows the scheme.
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            guard let source = UIImage(named: logo.asset, in: .module, compatibleWith: traits) else { return nil }
            let fitted = fit(source.size, in: side)
            let format = UIGraphicsImageRendererFormat(for: traits)
            let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                source.draw(in: CGRect(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2, width: fitted.width, height: fitted.height))
            }.withRenderingMode(logo.template ? .alwaysTemplate : .alwaysOriginal)
            asset.register(drawn, with: traits)
        }
        let image = Image(uiImage: asset.image(with: UITraitCollection.current))
        #else
        guard let source = Bundle.module.image(forResource: logo.asset) else { return nil }
        let fitted = fit(source.size, in: side)
        let drawn = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            source.draw(in: NSRect(x: (side - fitted.width) / 2, y: (side - fitted.height) / 2, width: fitted.width, height: fitted.height))
            return true
        }
        drawn.isTemplate = logo.template
        let image = Image(nsImage: drawn)
        #endif
        cache[logo] = image
        return image
    }

    private static func fit(_ size: CGSize, in side: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: side, height: side) }
        let scale = side / max(size.width, size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
