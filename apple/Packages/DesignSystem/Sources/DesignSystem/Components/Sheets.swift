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
    /// A Mac sheet's size from its first frame (resizable larger), so content that loads later
    /// scrolls inside it rather than growing it; iOS sheets size to the device.
    @ViewBuilder func macMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    /// Sheet detents on iPhone only.
    func phoneDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(PhoneDetents(detents: detents))
    }
}
