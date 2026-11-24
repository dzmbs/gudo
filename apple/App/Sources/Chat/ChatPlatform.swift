import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension View {
    /// The pointer's highlight on a Chat control: the system's on iPad, a quiet fill on the Mac.
    func chatHoverHighlight() -> some View {
        #if os(iOS)
        hoverEffect(.highlight)
        #else
        modifier(ChatHoverFill())
        #endif
    }
}

#if os(macOS)
private struct ChatHoverFill: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle.rounded(DS.Radius.control).fill(DS.Palette.hoverFill.opacity(isHovered ? 1 : 0)))
            .onHover { isHovered = $0 }
    }
}
#endif

extension Pasteboard {
    static var hasImage: Bool {
        #if canImport(UIKit)
        UIPasteboard.general.hasImages
        #else
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        #endif
    }

    /// The image on the clipboard as PNG, or nil when it holds none.
    static func imagePNG() -> Data? {
        #if canImport(UIKit)
        UIPasteboard.general.image?.pngData()
        #else
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #endif
    }
}

/// The line height the terminal font sets at `size` points, before Chat's line spacing.
@MainActor
enum ChatCodeMetrics {
    static func lineHeight(size: Double) -> CGFloat {
        #if canImport(UIKit)
        let font = TerminalFont.regular.flatMap { UIFont(name: $0, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return font.lineHeight
        #else
        let font = TerminalFont.regular.flatMap { NSFont(name: $0, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        return NSLayoutManager().defaultLineHeight(for: font)
        #endif
    }
}
