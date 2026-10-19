import SwiftUI

/// A transient confirmation ("Copied", "Approved"). Persistent problems never go in a toast.
nonisolated public struct Toast: Identifiable, Equatable, Sendable {
    public enum Style: Sendable { case neutral, success, failure }

    public let id = UUID()
    public var message: String
    public var systemImage: String?
    public var style: Style

    public init(_ message: String, systemImage: String? = nil, style: Style = .neutral) {
        self.message = message
        self.systemImage = systemImage
        self.style = style
    }
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
            guard (try? await Task.sleep(for: DS.Motion.toastDuration)) != nil else { return }
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
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.s + 2)
                .floatingCapsule(interactive: true)
                .onTapGesture { center.dismiss() }
                .padding(.top, DS.Space.s)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
                .accessibilityAddTraits(.isStaticText)
                .sensoryFeedback(toast.style == .failure ? DS.Haptic.failure : DS.Haptic.success, trigger: toast.id)
            }
        }
    }

    private func color(_ style: Toast.Style) -> Color {
        switch style {
        case .neutral: .secondary
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
