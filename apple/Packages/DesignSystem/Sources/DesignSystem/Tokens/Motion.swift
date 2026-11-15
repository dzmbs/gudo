import QuartzCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public extension DS.Motion.Role {
    /// The role's spring on a layer: set `fromValue` and `toValue`.
    func layerAnimation(keyPath: String) -> CASpringAnimation {
        let animation = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        animation.keyPath = keyPath
        animation.duration = animation.settlingDuration
        return animation
    }

    #if canImport(UIKit)
    var timingParameters: UISpringTimingParameters {
        UISpringTimingParameters(duration: spring.duration, bounce: spring.bounce)
    }
    #endif
}

/// What a transitioning view looks like away from rest: only opacity, scale and offset, so chrome
/// moves and fades without laying out again.
nonisolated public struct MotionFrame: Equatable, Sendable {
    public var opacity: Double
    public var scale: CGFloat
    public var offset: CGSize

    public static let rest = MotionFrame(opacity: 1, scale: 1, offset: .zero)

    /// The frame `progress` of the way from `self` to `rest`.
    public func toward(_ target: MotionFrame, progress: Double) -> MotionFrame {
        MotionFrame(
            opacity: opacity + (target.opacity - opacity) * progress,
            scale: scale + (target.scale - scale) * progress,
            offset: CGSize(
                width: offset.width + (target.offset.width - offset.width) * progress,
                height: offset.height + (target.offset.height - offset.height) * progress))
    }
}

/// The named transitions. Each fades; most also travel a few points or grow a little, and under
/// Reduce Motion they only fade.
nonisolated public struct MotionTransition: Transition, Sendable {
    public var scale: CGFloat
    public var offset: CGSize
    public var anchor: UnitPoint
    /// The spring it always runs on, so it never pops; `nil` rides the change's own animation.
    public var role: DS.Motion.Role?
    /// Waits for a structural move to arrive before showing.
    public var waitsForArrival: Bool

    public init(
        scale: CGFloat = 1, offset: CGSize = .zero, anchor: UnitPoint = .center,
        role: DS.Motion.Role? = nil, waitsForArrival: Bool = false
    ) {
        self.scale = scale
        self.offset = offset
        self.anchor = anchor
        self.role = role
        self.waitsForArrival = waitsForArrival
    }

    /// Away from rest (before appearing, after leaving).
    public func away(reduceMotion: Bool) -> MotionFrame {
        reduceMotion ? MotionFrame(opacity: 0, scale: 1, offset: .zero) : MotionFrame(opacity: 0, scale: scale, offset: offset)
    }

    public func body(content: Content, phase: TransitionPhase) -> some View {
        content.modifier(MotionFrameEffect(transition: self, isIdentity: phase.isIdentity))
    }

    /// Fades with whatever animation the change runs in.
    public static let fade = MotionTransition()

    /// Pills, badges, small buttons: grows from 86 %.
    public static func pill(anchor: UnitPoint = .center) -> MotionTransition {
        MotionTransition(scale: 0.86, anchor: anchor, role: .micro)
    }

    /// Toasts, banners and cards that arrive from an edge of the window.
    public static func toast(from edge: Edge) -> MotionTransition {
        MotionTransition(scale: 0.96, offset: edge.travel(16), anchor: edge.anchor, role: .standard)
    }

    /// A row arriving in or leaving a list.
    public static let row = MotionTransition(scale: 0.97, offset: CGSize(width: 0, height: -4), anchor: .top, role: .standard)

    /// Panels, bars, popovers and menus that open from an edge.
    public static func panel(from edge: Edge) -> MotionTransition {
        MotionTransition(scale: 0.98, offset: edge.travel(10), anchor: edge.anchor, role: .standard)
    }

    /// A card that grows in where it stands: a reconnect card, a presence card under its avatar.
    public static func card(anchor: UnitPoint = .center) -> MotionTransition {
        MotionTransition(scale: 0.96, anchor: anchor, role: .standard)
    }

    /// A tab's content, or a tab arriving in the strip.
    public static let tab = MotionTransition(scale: 0.985, role: .standard)

    /// Something that lands where a structural move is heading: it fades in as the move arrives
    /// and out at once.
    public static let arriving = MotionTransition(role: .micro, waitsForArrival: true)

    public static var properties: TransitionProperties { TransitionProperties(hasMotion: true) }
}

public extension View {
    /// Inserts and removes this view with a named transition.
    func motionTransition(_ transition: MotionTransition) -> some View {
        self.transition(transition.timed)
    }

    /// One beat that draws the eye when `trigger` changes: it grows a little and settles back.
    /// Nothing under Reduce Motion.
    func attentionCue(trigger: some Equatable) -> some View {
        modifier(AttentionCue(trigger: trigger))
    }
}

extension MotionTransition {
    var timed: AnyTransition {
        guard let role else { return AnyTransition(self) }
        let insertion = role.animation.delay(waitsForArrival ? DS.Motion.arrivalDelay : 0)
        return .asymmetric(insertion: AnyTransition(self).animation(insertion), removal: AnyTransition(self).animation(role.animation))
    }
}

public extension DS.Motion {
    /// How far `attentionCue` grows.
    static let attentionScale: CGFloat = 1.08
}

struct MotionFrameEffect: ViewModifier {
    let transition: MotionTransition
    let isIdentity: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let frame = isIdentity ? .rest : transition.away(reduceMotion: reduceMotion)
        content
            .opacity(frame.opacity)
            .scaleEffect(frame.scale, anchor: transition.anchor)
            .offset(frame.offset)
    }
}

private struct AttentionCue<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { content, scale in
            content.scaleEffect(reduceMotion ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(DS.Motion.attentionScale, duration: DS.Motion.Role.micro.budget, spring: DS.Motion.Role.micro.spring)
            SpringKeyframe(1, duration: DS.Motion.Role.standard.budget, spring: DS.Motion.Role.standard.spring)
        }
    }
}

nonisolated private extension Edge {
    func travel(_ distance: CGFloat) -> CGSize {
        switch self {
        case .top: CGSize(width: 0, height: -distance)
        case .bottom: CGSize(width: 0, height: distance)
        case .leading: CGSize(width: -distance, height: 0)
        case .trailing: CGSize(width: distance, height: 0)
        }
    }

    var anchor: UnitPoint {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}
