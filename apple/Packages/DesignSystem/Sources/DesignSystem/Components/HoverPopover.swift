import SwiftUI

/// A popover that opens on pointer hover (Mac, iPad with a pointer) and closes 150 ms after the
///
/// Content gets the system's popover padding and spacing (O3): give it `.padding()` and the
/// default `VStack` spacing, one fixed width and at most 400 tall, scrolling past that
/// (`hoverPopoverFrame()`).
public struct HoverPopover<Label: View, Content: View>: View {
    @Binding var isPresented: Bool
    let onClick: (() -> Void)?
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content
    @State private var overAnchor = false
    @State private var overPopover = false
    @State private var closing: Task<Void, Never>?

    /// The grace after the pointer leaves anchor and popover.
    public static var grace: Duration { .milliseconds(150) }

    public init(
        isPresented: Binding<Bool>, onClick: (() -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label, @ViewBuilder content: @escaping () -> Content
    ) {
        _isPresented = isPresented
        self.onClick = onClick
        self.label = label
        self.content = content
    }

    public var body: some View {
        Button {
            if let onClick { onClick() } else { isPresented.toggle() }
        } label: {
            label()
        }
        .onHover { inside in
            overAnchor = inside
            update()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content()
                .chromeContent()
                .onHover { inside in
                    overPopover = inside
                    update()
                }
                .presentationCompactAdaptation(.sheet)
                .presentationDetents([.medium, .large])
        }
    }

    private func update() {
        closing?.cancel()
        if overAnchor || overPopover {
            if !isPresented { isPresented = true }
        } else if isPresented {
            closing = Task { @MainActor in
                try? await Task.sleep(for: Self.grace)
                guard !Task.isCancelled, !overAnchor, !overPopover else { return }
                isPresented = false
            }
        }
    }
}

public extension DS.Size {
    /// Popovers: at most 400 tall, then they scroll.
    static let popoverMaxHeight: CGFloat = 400
    /// One width for content that changes while open, so a longer line never widens it.
    static let popoverWidth: CGFloat = 360
}

public extension View {
    /// A popover's content at the system padding, at one width, scrolling past 400 tall.
    func hoverPopoverFrame() -> some View {
        ScrollView {
            padding()
                .frame(width: DS.Size.popoverWidth, alignment: .leading)
        }
        .frame(maxHeight: DS.Size.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}
