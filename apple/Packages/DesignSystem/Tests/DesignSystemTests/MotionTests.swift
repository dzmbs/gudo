import SwiftUI
import Testing
@testable import DesignSystem

private let frameStep = 1.0 / 240

private func samples(until end: Double) -> [Double] {
    stride(from: 0, through: end, by: frameStep).map { $0 }
}

@Test(arguments: DS.Motion.Role.allCases)
func everyRoleIsCriticallyDamped(role: DS.Motion.Role) {
    #expect(role.spring.bounce == 0)
    #expect(abs(role.spring.dampingRatio - 1) < 1e-9)
}

@Test(arguments: DS.Motion.Role.allCases)
func everyRoleMovesOneWayWithoutOvershoot(role: DS.Motion.Role) {
    var last = 0.0
    for time in samples(until: 1) {
        let value = role.spring.value(target: 1.0, time: time)
        #expect(value >= last - 1e-12, "reverses at \(time) s")
        #expect(value <= 1 + 1e-9, "overshoots at \(time) s")
        last = value
    }
}

@Test(arguments: DS.Motion.Role.allCases)
func everyRoleSettlesWithinItsBudget(role: DS.Motion.Role) {
    let atBudget = role.spring.value(target: 1.0, time: role.budget)
    #expect(1 - atBudget <= 0.01, "\(role) is \(1 - atBudget) short at \(role.budget) s")
    let early = role.spring.value(target: 1.0, time: role.budget * 0.6)
    #expect(1 - early > 0.01, "\(role)'s budget is looser than its spring")
}

@Test func smallThingsSettleWellUnderTwoHundredMilliseconds() {
    #expect(DS.Motion.Role.micro.budget < 0.2)
    #expect(DS.Motion.Role.micro.budget < DS.Motion.Role.standard.budget)
    #expect(DS.Motion.Role.standard.budget < DS.Motion.Role.structural.budget)
}

@Test func structuralMovesAreWithinAPointWhenTheTerminalsRedraw() {
    let move = 600.0
    let left = move * (1 - DS.Motion.Role.structural.spring.value(target: 1.0, time: DS.Motion.structuralSettle))
    #expect(left < 1)
    #expect(DS.Motion.arrivalDelay + DS.Motion.Role.micro.budget <= DS.Motion.structuralSettle)
}

@Test func anInterruptedSpringKeepsItsSpeed() {
    let spring = DS.Motion.Role.standard.spring
    let cut = 0.06
    let position = spring.value(target: 1.0, time: cut)
    let speed = spring.velocity(target: 1.0, time: cut)
    // Sent back where it came from, it starts from where it was, at the speed it had.
    let reversed = { (time: Double) in position + spring.value(target: -position, initialVelocity: speed, time: time) }
    #expect(abs(reversed(0) - position) < 1e-9)
    let nextFrame = reversed(frameStep)
    #expect(nextFrame > position, "it carries on for a moment rather than snapping back")
}

private let named: [(String, MotionTransition)] = [
    ("fade", .fade),
    ("pill", .pill()),
    ("toast", .toast(from: .bottom)),
    ("row", .row),
    ("panel", .panel(from: .top)),
    ("card", .card()),
    ("tab", .tab),
    ("arriving", .arriving),
]

@Test func namedTransitionsOnlyFadeGrowAndTravelALittle() {
    for (name, transition) in named {
        let away = transition.away(reduceMotion: false)
        #expect(away.opacity == 0, "\(name) fades")
        #expect(away.scale >= 0.85 && away.scale <= 1, "\(name) grows a little")
        #expect(hypot(away.offset.width, away.offset.height) <= 16, "\(name) travels a few points")
        #expect(transition.role != nil || name == "fade", "\(name) runs on its own spring, so it never pops")
    }
}

@Test func namedTransitionsOnlyFadeUnderReduceMotion() {
    for (name, transition) in named {
        #expect(transition.away(reduceMotion: true) == MotionFrame(opacity: 0, scale: 1, offset: .zero), "\(name)")
    }
}

@Test func namedTransitionsArriveOnTheirClockWithinBudget() {
    for (name, transition) in named {
        let role = transition.role ?? .standard
        let delay = transition.waitsForArrival ? DS.Motion.arrivalDelay : 0
        let away = transition.away(reduceMotion: false)
        var previous = away
        for time in samples(until: delay + role.budget) {
            let progress = time < delay ? 0 : role.spring.value(target: 1.0, time: time - delay)
            let frame = away.toward(.rest, progress: progress)
            #expect(frame.opacity >= previous.opacity - 1e-12, "\(name) never fades back")
            #expect(frame.scale >= previous.scale - 1e-12, "\(name) never shrinks back")
            previous = frame
        }
        #expect(previous.opacity >= 0.99, "\(name) is visible by \(delay + role.budget) s")
        #expect(abs(previous.scale - 1) <= 0.01 * (1 - away.scale) + 1e-9, "\(name) is full size")
        #expect(hypot(previous.offset.width, previous.offset.height) <= 0.01 * 16 + 1e-9, "\(name) is in place")
    }
}

@MainActor
@Test func namedTransitionsNeverChangeLayout() throws {
    for (name, transition) in named {
        let rest = try #require(ImageRenderer(content: Swatch(transition: transition, isIdentity: true)).cgImage)
        let away = try #require(ImageRenderer(content: Swatch(transition: transition, isIdentity: false)).cgImage)
        #expect(rest.width == away.width && rest.height == away.height, "\(name) keeps its size")
    }
}

private struct Swatch: View {
    let transition: MotionTransition
    let isIdentity: Bool

    var body: some View {
        Rectangle()
            .frame(width: 40, height: 20)
            .modifier(MotionFrameEffect(transition: transition, isIdentity: isIdentity))
    }
}
