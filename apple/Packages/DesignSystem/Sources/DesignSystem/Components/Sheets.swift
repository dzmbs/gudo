import SwiftUI

private struct PhoneDetents: ViewModifier {
    let detents: Set<PresentationDetent>

    func body(content: Content) -> some View {
        // On iPad a sheet stays a centered form sheet and on the Mac a window-modal sheet;
        // resizable bottom sheets are a phone idiom.
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            content.presentationDetents(detents)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

public extension View {
    /// A minimum sheet size on the Mac; iOS sheets size to the device.
    @ViewBuilder func macMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }

    /// Sheet detents on iPhone only.
    func phoneDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(PhoneDetents(detents: detents))
    }
}
