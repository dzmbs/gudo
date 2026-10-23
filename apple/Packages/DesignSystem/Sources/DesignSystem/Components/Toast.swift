import SwiftUI

/// A transient confirmation ("Copied", "Approved"). Persistent problems never go in a toast.
nonisolated public struct Toast: Identifiable, Equatable, Sendable {
    public enum Style: Sendable { case neutral, success, failure }

    /// One button on the toast ("Undo"); it stays longer so there is time to reach it.
    public struct Action: Sendable {
        public var title: String
        public var perform: @MainActor @Sendable () -> Void

        public init(_ title: String, perform: @escaping @MainActor @Sendable () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    public let id = UUID()
    public var message: String
    public var systemImage: String?
    public var style: Style
    public var action: Action?

    public init(_ message: String, systemImage: String? = nil, style: Style = .neutral, action: Action? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.style = style
        self.action = action
    }

    public static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }

    var duration: Duration {
        if action != nil { return .seconds(5) }
        return style == .failure ? DS.Motion.bannerErrorDuration : DS.Motion.toastDuration
    }
}

/// Shows one toast at a time; a new toast replaces the current one.
@Observable
public final class ToastCenter {
    public private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ toast: Toast) {
        withAnimation(DS.Motion.banner) { current = toast }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard (try? await Task.sleep(for: toast.duration)) != nil else { return }
            withAnimation(DS.Motion.banner) { self?.current = nil }
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        withAnimation(DS.Motion.banner) { current = nil }
    }
}

/// address bar, an editor's bar, pane headers). The style's symbol sits in a small tinted disc
/// so it reads on any background; the action is the accent's word after a hairline. A tap, or a
/// flick down, dismisses it; taps beside it reach what is under it.
public struct Banner: View {
    let toast: Toast
    let dismiss: () -> Void
    @State private var drag: CGFloat = 0

    public init(_ toast: Toast, dismiss: @escaping () -> Void) {
        self.toast = toast
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: DS.Space.gap10) {
            if let image = toast.systemImage {
                // The disc is the circle: a circled symbol inside it would be a ring in a ring.
                Image(systemName: image.replacingOccurrences(of: ".circle.fill", with: "").replacingOccurrences(of: ".circle", with: ""))
                    .font(.footnote.weight(.bold))
                    .imageScale(.small)
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.16), in: .circle)
                    .accessibilityHidden(true)
            }
            Text(toast.message)
                .font(DS.Font.banner)
                .foregroundStyle(DS.Palette.text)
                // One line; a failure may take a second, since its reason is the point.
                .lineLimit(toast.style == .failure ? 2 : 1)
                .truncationMode(.middle)
            if let action = toast.action {
                Hairline(.vertical)
                    .frame(height: 16)
                Button(action.title) {
                    dismiss()
                    action.perform()
                }
                .font(DS.Font.banner.weight(.semibold))
                .foregroundStyle(DS.Palette.accent)
                .buttonStyle(.plain)
                .accessibilityIdentifier("toast-action")
            }
        }
        .padding(.leading, toast.systemImage == nil ? DS.Space.l : DS.Space.s)
        .padding(.trailing, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: 40)
        .chromeContent()
        .floatingCapsule(interactive: true)
        // As wide as its words, up to a line a glance takes in.
        .frame(maxWidth: 560)
        .offset(y: max(0, drag))
        // A tap dismisses; with a button only the button takes taps.
        .gesture(TapGesture().onEnded { dismiss() }, including: toast.action == nil ? .all : .subviews)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 16 || value.velocity.height > 300 {
                        dismiss()
                    } else {
                        withAnimation(DS.Motion.banner) { drag = 0 }
                    }
                })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(toast.message)
        .accessibilityIdentifier("toast")
    }

    private var tint: ChromeStyle {
        switch toast.style {
        case .neutral: DS.Palette.textSecondary
        case .success: DS.Palette.done
        case .failure: DS.Palette.error
        }
    }
}

private struct ToastHost: ViewModifier {
    let center: ToastCenter
    let bottomInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                Banner(toast) { center.dismiss() }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, bottomInset)
                    .transition(BannerTransition.value)
                    .id(toast.id)
                    .sensoryFeedback(toast.style == .failure ? DS.Haptic.failure : DS.Haptic.success, trigger: toast.id)
            }
        }
    }
}

/// From below with a slight grow; a fade under Reduce Motion.
private struct BannerTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool

    static var value: AnyTransition {
        .modifier(active: BannerTransition(active: true), identity: BannerTransition(active: false))
    }

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .scaleEffect(active && !reduceMotion ? 0.9 : 1, anchor: .bottom)
            .offset(y: active && !reduceMotion ? 24 : 0)
            .blur(radius: active && !reduceMotion ? 4 : 0)
    }
}

public extension View {
    /// Banners for `center`, `bottomInset` over the bottom safe area (and the keyboard).
    func toastHost(_ center: ToastCenter, bottomInset: CGFloat = DS.Space.l) -> some View {
        modifier(ToastHost(center: center, bottomInset: bottomInset))
    }
}
