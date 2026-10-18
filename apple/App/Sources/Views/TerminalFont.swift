import CoreText
import Foundation
import SwiftUI

/// The terminal's bundled JetBrains Mono, registered for the app's own previews (the theme picker
/// and the font sample in Settings). The renderer loads the same files itself.
enum TerminalFont {
    /// PostScript name of the regular face, once registered.
    static let regular: String? = {
        guard let bundle = Bundle.main.url(forResource: "TerminalKit_TerminalRenderer", withExtension: "bundle")
                .flatMap(Bundle.init(url:)),
              let url = bundle.url(forResource: "JetBrainsMonoNerdFont-Regular", withExtension: "ttf", subdirectory: "Fonts")
        else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first
        else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }()

    static func font(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        regular.map { .custom($0, size: size, relativeTo: style) } ?? .system(size: size, design: .monospaced)
    }
}
