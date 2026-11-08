import Foundation
import os

/// Milestones from a tab action to its terminal on screen, as `Tab handoff` signposts and `tabs` log lines.
nonisolated enum TabTimeline {
    enum Action: String, Sendable {
        case newTab = "new tab"
        case selectTab = "select tab"
    }

    enum Milestone: String, Sendable {
        case chipInserted = "chip inserted"
        case scrolledIntoView = "scrolled into view"
        case backendReady = "backend ready"
        case firstSnapshot = "first snapshot"
        case surfaceReady = "surface ready"
        case focusHandedOver = "focus handed over"
        case firstFramePresented = "first frame presented"
        case deadlinePassed = "shown at the deadline"
    }

    private struct Run {
        let action: Action
        let start: ContinuousClock.Instant
        let interval: OSSignpostIntervalState
        var reached: Set<Milestone> = []

        var isComplete: Bool {
            reached.contains(.focusHandedOver) && (reached.contains(.firstFramePresented) || reached.contains(.deadlinePassed))
        }
    }

    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "app", category: .pointsOfInterest)
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "tabs")
    private static let current = OSAllocatedUnfairLock<Run?>(uncheckedState: nil)
    /// A run that never completes (its tab closed on the way) stops counting after this.
    static let abandonAfter = Duration.seconds(5)

    static func began(_ action: Action) {
        let interval = signposter.beginInterval("Tab handoff", id: signposter.makeSignpostID(), "\(action.rawValue, privacy: .public)")
        let previous = current.withLock { run in
            defer { run = Run(action: action, start: .now, interval: interval) }
            return run
        }
        if let previous { signposter.endInterval("Tab handoff", previous.interval, "superseded") }
    }

    static func mark(_ milestone: Milestone) {
        let now = ContinuousClock.now
        let marked: (run: Run, elapsed: Duration)? = current.withLock { run in
            guard var active = run, !active.reached.contains(milestone) else { return nil }
            let elapsed = now - active.start
            guard elapsed < abandonAfter else {
                run = nil
                return nil
            }
            active.reached.insert(milestone)
            run = active.isComplete ? nil : active
            return (active, elapsed)
        }
        guard let (run, elapsed) = marked else { return }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        signposter.emitEvent("Tab milestone", "\(milestone.rawValue, privacy: .public)")
        log.info("\(run.action.rawValue, privacy: .public): \(milestone.rawValue, privacy: .public) +\(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        if run.isComplete { signposter.endInterval("Tab handoff", run.interval) }
    }
}
