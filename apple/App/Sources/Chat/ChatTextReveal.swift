// Paced reveal adapted from Paseo, Copyright (c) 2025-present Mohamed Boudra, Apache-2.0.
// Modified to count rendered characters across native block rows.
import Foundation

/// How much of a streaming reply is on screen. Text arrives in lumps, one per daemon window, so
/// arrival sets a target and the reveal rate follows the backlog: a burst catches up faster
/// instead of jumping. Only growth is paced; a reply seen for the first time shows whole.
nonisolated struct ChatTextReveal: Equatable, Sendable {
    /// The backlog drains over this horizon. Shorter shows the lumps; longer lags at a turn's end.
    static let horizon: Duration = .milliseconds(150)
    /// The reveal advances at most once per 60 Hz frame, even on a faster display.
    static let frameInterval: Duration = .microseconds(16_667)
    /// A stalled frame (a busy main thread, a hidden window) counts as this long at most.
    static let maximumElapsed: Duration = .milliseconds(250)

    private(set) var target: Int
    private(set) var revealed: Int

    /// A text seen for the first time is shown whole.
    init(showing length: Int) {
        precondition(length >= 0)
        target = length
        revealed = length
    }

    var isSettled: Bool { revealed >= target }

    /// Points the reveal at the text's current length without changing how much is shown.
    mutating func retarget(_ length: Int) {
        precondition(length >= 0)
        target = length
        revealed = min(revealed, length)
    }

    /// Releases one frame's worth of the backlog.
    mutating func advance(by elapsed: Duration, horizon: Duration = Self.horizon) {
        revealed += Self.step(backlog: target - revealed, elapsed: elapsed, horizon: horizon)
        assert(revealed <= target, "the reveal passed its text")
    }

    /// Shows everything: the reply stopped streaming and nothing may be held back.
    mutating func complete() { revealed = target }

    /// Characters to reveal for a frame `elapsed` long: proportional to the backlog, so the
    /// reveal speeds up when the agent runs ahead, with a one-character floor so the tail ends.
    static func step(backlog: Int, elapsed: Duration, horizon: Duration = Self.horizon) -> Int {
        guard backlog > 0 else { return 0 }
        guard horizon > .zero else { return backlog }
        let elapsed = min(max(elapsed, .zero), maximumElapsed)
        guard elapsed > .zero else { return 0 }
        guard elapsed < horizon else { return backlog }
        let step = (Double(backlog) * (elapsed / horizon)).rounded(.up)
        return min(backlog, max(1, Int(step)))
    }

    /// The elapsed time of the frame at `now`, or nil until a 60 Hz frame has passed since
    /// `previous`. The returned frame time keeps the remainder, so a 120 Hz display reveals at 60.
    static func frame(after previous: ContinuousClock.Instant?, at now: ContinuousClock.Instant)
        -> (elapsed: Duration, frameTime: ContinuousClock.Instant)? {
        guard let previous else { return (frameInterval, now) }
        let elapsed = previous.duration(to: now)
        guard elapsed >= frameInterval else { return nil }
        let remainder = elapsed - frameInterval * (elapsed / frameInterval).rounded(.down)
        return (elapsed, now - remainder)
    }
}
