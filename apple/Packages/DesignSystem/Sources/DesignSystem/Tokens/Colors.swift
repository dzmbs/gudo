import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public extension Color {
    /// `#RRGGBB` or `RRGGBB`; anything else is magenta so a typo is impossible to miss.
    nonisolated init(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = Color(red: 1, green: 0, blue: 1)
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// A color that follows the light/dark appearance of whatever draws it.
    nonisolated init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
        #endif
    }
}

public extension DS {
    /// Chrome colors. Chrome is monochrome (system label/fill colors); color is reserved for state
    /// Ghostty's default palette so the chrome and the terminal read as one surface; light-mode
    /// variants are darkened to pass 4.5:1 on white.
    nonisolated enum Palette {
        /// The brand accent: Ghostty's bright blue (palette 12, #7AA6DA) on dark, darkened for light.
        /// Used for focus, selection and the single primary action, nothing decorative.
        public static let accent = Color(light: Color(hex: "#2F6DB5"), dark: Color(hex: "#7AA6DA"))

        /// Agent working (Ghostty yellow, palette 3).
        public static let working = Color(light: Color(hex: "#A87A00"), dark: Color(hex: "#F0C674"))
        /// Agent blocked / needs you (Ghostty bright red, palette 9).
        public static let blocked = Color(light: Color(hex: "#C8323A"), dark: Color(hex: "#E8686C"))
        /// Agent done (Ghostty green, palette 2).
        public static let done = Color(light: Color(hex: "#4E7A12"), dark: Color(hex: "#B5BD68"))
        /// Failure (Ghostty red, palette 1).
        public static let error = Color(light: Color(hex: "#B83A3A"), dark: Color(hex: "#CC6666"))
        /// Informational (Ghostty blue, palette 4).
        public static let info = Color(light: Color(hex: "#3F6E99"), dark: Color(hex: "#81A2BE"))

        /// Ghostty's bell border: #FFCC00 at 50 %.
        public static let bell = Color(red: 1, green: 0.8, blue: 0).opacity(0.5)

        /// tab hover 5 % + 13 % backdrop).
        public static let hoverFill = Color.primary.opacity(0.06)
        public static let pressedFill = Color.primary.opacity(0.10)
        public static let selectedFill = Color.primary.opacity(0.09)
    }
}
