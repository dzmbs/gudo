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

    var duration: Duration { action == nil ? DS.Motion.toastDuration : .seconds(5) }
}

/// Shows one toast at a time; a new toast replaces the current one.
@Observable
public final class ToastCenter {
    public private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ toast: Toast) {
        withAnimation(DS.Motion.indicator) { current = toast }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard (try? await Task.sleep(for: toast.duration)) != nil else { return }
            withAnimation(DS.Motion.overlay) { self?.current = nil }
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        withAnimation(DS.Motion.overlay) { current = nil }
    }
}

private struct ToastHost: ViewModifier {
    let center: ToastCenter

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast = center.current {
                HStack(spacing: DS.Space.s) {
                    if let image = toast.systemImage {
                        Image(systemName: image)
                            .foregroundStyle(color(toast.style))
                    }
                    Text(toast.message)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if let action = toast.action {
                        Button(action.title) {
                            center.dismiss()
                            action.perform()
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(DS.Palette.accent)
                        .buttonStyle(.plain)
                        .padding(.leading, DS.Space.xs)
                        .accessibilityIdentifier("toast-action")
                    }
                }
                .chromeContent()
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.gap10)
                .floatingCapsule(interactive: true)
                .onTapGesture { center.dismiss() }
                .padding(.top, DS.Space.s)
                .movingTransition(.top)
                .id(toast.id)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("toast")
                .sensoryFeedback(toast.style == .failure ? DS.Haptic.failure : DS.Haptic.success, trigger: toast.id)
            }
        }
    }

    private func color(_ style: Toast.Style) -> ChromeStyle {
        switch style {
        case .neutral: DS.Palette.textSecondary
        case .success: DS.Palette.done
        case .failure: DS.Palette.error
        }
    }
}

public extension View {
    func toastHost(_ center: ToastCenter) -> some View {
        modifier(ToastHost(center: center))
    }
}
