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

private struct FittedForm<Step: Equatable>: ViewModifier {
    let maxHeight: CGFloat
    let step: Step
    /// Also an iPad's form sheet, which otherwise takes a fixed size far taller than a short form.
    var onPad = false
    /// Measured in the first layout pass, before the sheet shows.
    @State private var height: CGFloat?
    /// Until when the form's height follows its rows: from its first rows on as it opens, and
    /// briefly after each step.
    @State private var settlesAt: ContinuousClock.Instant?
    @State private var measuredStep: Step?

    func body(content: Content) -> some View {
        #if os(macOS)
        measured(content)
            .frame(height: fitted)
        #else
        if onPad, UIDevice.current.userInterfaceIdiom == .pad {
            // The form's own height (its insets include the bar) proposed to the sheet directly:
            // a navigation stack does not pass an ideal height up for `fitted` to use.
            measured(content)
                .presentationSizing(FormHeight(height: height.map { min($0, maxHeight) }))
        } else {
            content
        }
        #endif
    }

    private var fitted: CGFloat { min(height ?? maxHeight / 2, maxHeight) }

    private func measured(_ content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, measured in
                // Rows a host sends later scroll inside; only the user's steps resize the sheet.
                guard measured > 0 else { return }
                if settlesAt == nil || measuredStep != step { settlesAt = .now + FittedFormTiming.settle }
                guard let settlesAt, ContinuousClock.now < settlesAt else { return }
                height = measured
                measuredStep = step
            }
            .onChange(of: step) { settlesAt = .now + FittedFormTiming.settle }
    }
}

#if os(iOS)
/// A form sheet's size with the form's height, never taller than a form sheet would be.
private struct FormHeight: PresentationSizing {
    let height: CGFloat?

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let form: FormPresentationSizing = .form
        var size = form.proposedSize(for: root, context: context)
        if let height { size.height = min(height, size.height ?? height) }
        return size
    }
}
#endif

enum FittedFormTiming {
    /// How long a fitted form's height follows its rows after it opens or takes a step.
    static let settle = Duration.milliseconds(250)
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

    /// A Mac sheet's form as tall as its rows when it opens, up to `maxHeight` (then it
    /// scrolls): no blank space under it, and the system places it by that height. Rows that
    /// arrive later (a host's answer) scroll inside it; it resizes only when `step` changes,
    /// the user moving the form on (a pasted link, another mode).
    func macFittedForm(maxHeight: CGFloat, step: some Equatable = 0) -> some View {
        modifier(FittedForm(maxHeight: maxHeight, step: step))
    }

    /// `macFittedForm`, and on iPad a form sheet as tall as the form too (a short notice
    /// otherwise opens in a page-tall sheet on a large iPad).
    func fittedForm(maxHeight: CGFloat, step: some Equatable = 0) -> some View {
        modifier(FittedForm(maxHeight: maxHeight, step: step, onPad: true))
    }

    /// Sheet detents on iPhone only.
    func phoneDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(PhoneDetents(detents: detents))
    }
}
