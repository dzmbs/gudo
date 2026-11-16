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
    /// Someone the banner is about (joined, left): their avatar leads instead of the symbol.
    public var person: Participant?

    public init(_ message: String, systemImage: String? = nil, style: Style = .neutral, action: Action? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.style = style
        self.action = action
    }

    public static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }

    /// Says the same thing as `other`: shown again, it refreshes the toast on screen instead of
    /// replacing it.
    public func repeats(_ other: Toast) -> Bool {
        message == other.message && systemImage == other.systemImage && style == other.style
            && action?.title == other.action?.title && person?.id == other.person?.id
    }

    var duration: Duration {
        if action != nil { return .seconds(5) }
        return style == .failure ? DS.Motion.bannerErrorDuration : DS.Motion.toastDuration
    }
}

/// Shows one toast at a time; a new toast replaces the current one, and the same toast again
/// keeps it on screen for its full time.
@Observable
public final class ToastCenter {
    public private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    public init() {}

    public func show(_ toast: Toast) {
        if let current, current.repeats(toast) {
            self.current?.action = toast.action
        } else {
            withAnimation(DS.Motion.standard) { current = toast }
        }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard (try? await Task.sleep(for: toast.duration)) != nil else { return }
            withAnimation(DS.Motion.standard) { self?.current = nil }
        }
    }

    public func dismiss() {
        dismissTask?.cancel()
        withAnimation(DS.Motion.standard) { current = nil }
    }

    /// Cards at the bottom of panes (others' drafts, a guest's composer), in global
    /// coordinates: the banner rises above any it would cover.
    private(set) var obstacles: [AnyHashable: CGRect] = [:]

    func setObstacle(_ id: AnyHashable, _ frame: CGRect?) {
        let frame = frame.flatMap { $0.isEmpty ? nil : $0 }
        guard obstacles[id] != frame else { return }
        obstacles[id] = frame
    }

    public static func bottomInset(
        base: CGFloat, banner size: CGSize, in host: CGRect, avoiding obstacles: [CGRect], spacing: CGFloat = DS.Space.s,
        position: ToastPosition = .bottomLeading
    ) -> CGFloat {
        var inset = base
        for obstacle in obstacles.sorted(by: { $0.maxY > $1.maxY }) {
            let banner = CGRect(x: bannerX(size, in: host, position: position), y: host.maxY - inset - size.height, width: size.width, height: size.height)
            if banner.intersects(obstacle) { inset = host.maxY - obstacle.minY + spacing }
        }
        return inset
    }

    /// The top-edge counterpart: the banner drops below any card it would cover.
    public static func topInset(
        base: CGFloat, banner size: CGSize, in host: CGRect, avoiding obstacles: [CGRect], spacing: CGFloat = DS.Space.s,
        position: ToastPosition = .topTrailing
    ) -> CGFloat {
        var inset = base
        for obstacle in obstacles.sorted(by: { $0.minY < $1.minY }) {
            let banner = CGRect(x: bannerX(size, in: host, position: position), y: host.minY + inset, width: size.width, height: size.height)
            if banner.intersects(obstacle) { inset = obstacle.maxY - host.minY + spacing }
        }
        return inset
    }

    private static func bannerX(_ size: CGSize, in host: CGRect, position: ToastPosition) -> CGFloat {
        switch position.horizontalAlignment {
        case .trailing: host.maxX - DS.Space.l - size.width
        case .center: host.midX - size.width / 2
        default: host.minX + DS.Space.l
        }
    }
}

private struct ToastCenterKey: EnvironmentKey {
    static let defaultValue: ToastCenter? = nil
}

extension EnvironmentValues {
    /// The banners of the window around this view (`toastHost`).
    var toastCenter: ToastCenter? {
        get { self[ToastCenterKey.self] }
        set { self[ToastCenterKey.self] = newValue }
    }
}

/// Reports a view's frame to the window's banners so they never cover it.
private struct ToastObstacle: ViewModifier {
    @Environment(\.toastCenter) private var center
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { center?.setObstacle(id, $0) }
            .onDisappear { center?.setObstacle(id, nil) }
    }
}

/// Where a window's toasts appear: bottom leading by default, or top trailing or bottom centre.
nonisolated public enum ToastPosition: String, CaseIterable, Identifiable, Sendable {
    case bottomLeading = "bottom-leading"
    case topTrailing = "top-trailing"
    case bottomCenter = "bottom-center"

    public static let key = "toast-position"
    public static let standard = ToastPosition.bottomLeading

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bottomLeading: "Bottom Left"
        case .topTrailing: "Top Right"
        case .bottomCenter: "Bottom Centre"
        }
    }

    public var alignment: Alignment {
        switch self {
        case .bottomLeading: .bottomLeading
        case .topTrailing: .topTrailing
        case .bottomCenter: .bottom
        }
    }

    /// The edge a toast arrives from and is flicked back to.
    public var edge: Edge {
        switch self {
        case .bottomLeading, .bottomCenter: .bottom
        case .topTrailing: .top
        }
    }

    /// The edge the toast stack of agents slides in from: the side the stack sits on.
    public var stackEdge: Edge {
        switch self {
        case .bottomLeading: .leading
        case .topTrailing: .trailing
        case .bottomCenter: .bottom
        }
    }

    public var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .bottomLeading: .leading
        case .topTrailing: .trailing
        case .bottomCenter: .center
        }
    }
}

/// One line in a glass capsule that rises from its edge, clear of every pane's top bar. The
/// style's symbol sits in a small tinted disc so it reads on any background. A tap, or a flick
/// toward its edge, dismisses it; taps beside it reach what is under it. Under Differentiate
/// Without Color a success or failure always shows its symbol, and a failure's disc is square;
/// under Increase Contrast the capsule takes a border.
public struct Banner: View {
    let toast: Toast
    let edge: Edge
    let alignment: HorizontalAlignment
    let dismiss: () -> Void
    @State private var dragOffset: CGFloat = 0
    @Environment(\.chromeAccessibility) private var accessibility
    @Environment(\.displayScale) private var displayScale

    /// `alignment` is the side of its line it keeps to when the words are short.
    public init(_ toast: Toast, edge: Edge = .bottom, alignment: HorizontalAlignment = .leading, dismiss: @escaping () -> Void) {
        self.toast = toast
        self.edge = edge
        self.alignment = alignment
        self.dismiss = dismiss
    }

    /// Toward the edge it came from is positive.
    private var flickSign: CGFloat { edge == .top ? -1 : 1 }

    public var body: some View {
        HStack(spacing: DS.Space.gap10) {
            if let person = toast.person {
                PresenceAvatar(person, size: 24)
                    .accessibilityHidden(true)
            } else if let image = symbol {
                // The disc is the circle: a circled symbol inside it would be a ring in a ring.
                Image(systemName: image.replacingOccurrences(of: ".circle.fill", with: "").replacingOccurrences(of: ".circle", with: ""))
                    .font(.footnote.weight(.bold))
                    .imageScale(.small)
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(DS.Palette.container(tint), in: discShape)
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
        .padding(.leading, symbol == nil && toast.person == nil ? DS.Space.l : DS.Space.s)
        .padding(.trailing, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: 40)
        .chromeContent()
        .floatingCapsule(interactive: true)
        .overlay {
            if accessibility.increaseContrast {
                Capsule()
                    .strokeBorder(DS.Palette.border, lineWidth: DS.Size.hairline(scale: displayScale) * accessibility.ringPixels)
                    .allowsHitTesting(false)
            }
        }
        // As wide as its words, up to a line a glance takes in.
        .frame(maxWidth: 560, alignment: Alignment(horizontal: alignment, vertical: .center))
        .offset(y: flickSign * max(0, dragOffset))
        // A tap dismisses; with a button only the button takes taps.
        .gesture(TapGesture().onEnded { dismiss() }, including: toast.action == nil ? .all : .subviews)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { dragOffset = flickSign * $0.translation.height }
                .onEnded { value in
                    if flickSign * value.translation.height > 16 || flickSign * value.velocity.height > 300 {
                        dismiss()
                    } else {
                        withAnimation(accessibility.travel(DS.Motion.standard)) { dragOffset = 0 }
                    }
                })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenMessage)
        .accessibilityIdentifier("toast")
    }

    /// The toast's symbol; under Differentiate Without Color its style's own when it has none.
    private var symbol: String? {
        if let image = toast.systemImage { return image }
        guard accessibility.marksStateWithShape else { return nil }
        switch toast.style {
        case .neutral: return nil
        case .success: return "checkmark"
        case .failure: return "exclamationmark"
        }
    }

    private var discShape: AnyShape {
        toast.style == .failure && accessibility.marksStateWithShape ? AnyShape(.rounded(DS.Radius.field)) : AnyShape(Circle())
    }

    /// The message, said as a failure when it is one: the tint is not heard.
    private var spokenMessage: String {
        toast.style == .failure ? "Failed: \(toast.message)" : toast.message
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
    let topInset: CGFloat
    let leadingInset: CGFloat

    @State private var host = CGRect.zero
    @State private var size = CGSize.zero
    @AppStorage(ToastPosition.key) private var position = ToastPosition.standard
    @Environment(\.chromeAccessibility) private var accessibility

    func body(content: Content) -> some View {
        content
            .environment(\.toastCenter, center)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { host = $0 }
            .overlay(alignment: position.alignment) {
                if let toast = center.current {
                    Banner(toast, edge: position.edge, alignment: position.horizontalAlignment) { center.dismiss() }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                        .padding(.horizontal, DS.Space.l)
                        .padding(.leading, position == .bottomLeading ? leadingInset : 0)
                        .padding(position.edge == .top ? .top : .bottom, position.edge == .top ? topInset : bottomInset)
                        .offset(y: obstacleOffset)
                        .animation(accessibility.travel(DS.Motion.standard), value: center.obstacles.count)
                        .motionTransition(.toast(from: position.edge))
                        .id(toast.id)
                        .sensoryFeedback(toast.style == .failure ? DS.Haptic.failure : DS.Haptic.success, trigger: toast.id)
                }
            }
    }

    /// How far the banner moves off its inset to clear the cards it would cover.
    private var obstacleOffset: CGFloat {
        let obstacles = Array(center.obstacles.values)
        if position.edge == .top {
            return ToastCenter.topInset(base: topInset, banner: size, in: host, avoiding: obstacles, position: position) - topInset
        }
        return bottomInset - ToastCenter.bottomInset(base: bottomInset, banner: size, in: host, avoiding: obstacles, position: position)
    }
}

public extension View {
    /// Banners for `center` at the user's `ToastPosition`: `bottomInset` over the bottom safe
    /// area (and the keyboard), `topInset` under the top one, and at the bottom left
    /// `leadingInset` clear of a sidebar there.
    func toastHost(
        _ center: ToastCenter, bottomInset: CGFloat = DS.Space.l, topInset: CGFloat = DS.Space.l, leadingInset: CGFloat = 0
    ) -> some View {
        modifier(ToastHost(center: center, bottomInset: bottomInset, topInset: topInset, leadingInset: leadingInset))
    }

    /// Keeps the window's banners (`toastHost`) clear of this view: a card at the bottom of a
    /// pane that a banner rising from the window's bottom would otherwise cover.
    func toastObstacle() -> some View {
        modifier(ToastObstacle())
    }
}
