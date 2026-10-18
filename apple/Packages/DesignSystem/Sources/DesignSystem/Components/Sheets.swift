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
    /// Sheet detents on iPhone only.
    func phoneDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(PhoneDetents(detents: detents))
    }
}
