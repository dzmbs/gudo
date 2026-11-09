import Foundation
import os
import Synchronization

/// Times keys from the moment the system received them to the frame on screen that shows them,
/// in system uptime seconds (`CACurrentMediaTime`, event and drawable timestamps). One key at a
/// time: keys typed while one is in flight are not timed.
///
/// - `toFeedback`: to the first frame showing the key, a predicted echo or IME text included.
/// - `toEcho`: to the first frame showing the host's output, split into `keyToSent` (the app),
///   `sentToOutput` (network and host), `outputToFrame` (waiting for and building the frame) and
///   `frameToScreen` (GPU and compositor).
public final class KeyToScreen: Sendable {
    /// Milliseconds.
    public struct Percentiles: Sendable, Equatable, CustomStringConvertible {
        public var p50: Double, p95: Double, p99: Double, max: Double

        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            func rank(_ fraction: Double) -> Double {
                sorted[Swift.max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1)]
            }
            p50 = rank(0.50)
            p95 = rank(0.95)
            p99 = rank(0.99)
            max = sorted.last ?? 0
        }

        public var description: String {
            String(format: "%.1f/%.1f/%.1f/%.1f", p50, p95, p99, max)
        }
    }

    public struct Summary: Sendable, Equatable, CustomStringConvertible {
        public var count: Int
        public var toFeedback: Percentiles
        public var toEcho: Percentiles
        public var keyToSent: Percentiles
        public var sentToOutput: Percentiles
        public var outputToFrame: Percentiles
        public var frameToScreen: Percentiles

        public var description: String {
            "keys=\(count) p50/p95/p99/max ms: feedback \(toFeedback) echo \(toEcho) "
                + "(app \(keyToSent), network and host \(sentToOutput), frame \(outputToFrame), screen \(frameToScreen))"
        }
    }

    /// A frame being encoded that shows a timed key: hand it back with the time it was presented.
    public struct Frame: Sendable, Equatable {
        fileprivate let key: UInt64
        fileprivate let isFeedback: Bool
        fileprivate let isEcho: Bool
        fileprivate let encodedAt: Double
    }

    /// Seconds after which a key with nothing to show stops being timed (a key that prints
    /// nothing, or a host that went away).
    static let abandonAfter: Double = 1
    /// Samples summarized into one log line.
    static let logEvery = 200

    private struct Key {
        let id: UInt64
        let receivedAt: Double
        let sentAt: Double
        let signpostID: OSSignpostID
        let signpost: OSSignpostIntervalState
        var outputSerial: UInt64?
        var outputAt: Double?
        var isFeedbackClaimed = false
        var isEchoClaimed = false
        var feedbackAt: Double?

        func isAbandoned(at time: Double) -> Bool { time - receivedAt > KeyToScreen.abandonAfter }
    }

    private struct Sample {
        var toFeedback: Double, toEcho: Double
        var keyToSent: Double, sentToOutput: Double, outputToFrame: Double, frameToScreen: Double
    }

    private struct State {
        var key: Key?
        var nextKeyId: UInt64 = 1
        var samples: [Sample] = []
    }

    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "terminal", category: .pointsOfInterest)
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "terminal", category: "latency")
    private let state = Mutex(State())

    public init() {}

    /// A key the system received at `receivedAt` produced input sent at `sentAt`.
    public func keyReceived(at receivedAt: Double, sentAt: Double) {
        state.withLock { state in
            if let key = state.key, !key.isAbandoned(at: sentAt) { return }
            if let abandoned = state.key { Self.signposter.endInterval("Key to screen", abandoned.signpost, "abandoned") }
            let signpostID = Self.signposter.makeSignpostID()
            let signpost = Self.signposter.beginInterval("Key to screen", id: signpostID)
            state.key = Key(id: state.nextKeyId, receivedAt: receivedAt, sentAt: sentAt, signpostID: signpostID, signpost: signpost)
            state.nextKeyId += 1
        }
    }

    /// Output with this serial was written to the terminal at `time`.
    public func outputArrived(serial: UInt64, at time: Double) {
        state.withLock { state in
            guard var key = state.key, key.outputSerial == nil else { return }
            if key.isAbandoned(at: time) {
                Self.signposter.endInterval("Key to screen", key.signpost, "abandoned")
                state.key = nil
                return
            }
            key.outputSerial = serial
            key.outputAt = time
            state.key = key
        }
    }

    /// A frame built at `time` from the terminal as of output `serial`, possibly showing typed
    /// input drawn locally (a predicted echo, IME text). Returns what the frame shows of the timed
    /// key, or nil when it shows nothing new.
    public func frameEncoding(showingOutput serial: UInt64, showsLocalEcho: Bool, at time: Double) -> Frame? {
        state.withLock { state in
            guard var key = state.key else { return nil }
            if key.isAbandoned(at: time) {
                Self.signposter.endInterval("Key to screen", key.signpost, "abandoned")
                state.key = nil
                return nil
            }
            let isEcho = !key.isEchoClaimed && key.outputSerial.map { serial >= $0 } == true
            let isFeedback = !key.isFeedbackClaimed && (isEcho || showsLocalEcho)
            guard isEcho || isFeedback else { return nil }
            key.isEchoClaimed = key.isEchoClaimed || isEcho
            key.isFeedbackClaimed = key.isFeedbackClaimed || isFeedback
            state.key = key
            return Frame(key: key.id, isFeedback: isFeedback, isEcho: isEcho, encodedAt: time)
        }
    }

    /// `frame` reached the screen at `time`; 0 means it never did.
    public func framePresented(_ frame: Frame, at time: Double) {
        let summary: Summary? = state.withLock { state in
            guard var key = state.key, key.id == frame.key else { return nil }
            guard time > 0 else {
                if frame.isEcho { key.isEchoClaimed = false }
                if frame.isFeedback { key.isFeedbackClaimed = false }
                state.key = key
                return nil
            }
            if frame.isFeedback {
                key.feedbackAt = time
                Self.signposter.emitEvent("Key feedback on screen", id: key.signpostID)
            }
            guard frame.isEcho, let outputAt = key.outputAt else {
                state.key = key
                return nil
            }
            state.key = nil
            Self.signposter.endInterval("Key to screen", key.signpost)
            state.samples.append(Sample(
                toFeedback: milliseconds(from: key.receivedAt, to: key.feedbackAt ?? time),
                toEcho: milliseconds(from: key.receivedAt, to: time),
                keyToSent: milliseconds(from: key.receivedAt, to: key.sentAt),
                sentToOutput: milliseconds(from: key.sentAt, to: outputAt),
                outputToFrame: milliseconds(from: outputAt, to: frame.encodedAt),
                frameToScreen: milliseconds(from: frame.encodedAt, to: time)))
            guard state.samples.count >= Self.logEvery else { return nil }
            return Self.summarize(&state.samples)
        }
        if let summary { Self.log.info("key to screen \(summary.description, privacy: .public)") }
    }

    /// The keys timed since the last call, or nil if none were.
    public func drain() -> Summary? {
        state.withLock { Self.summarize(&$0.samples) }
    }

    private static func summarize(_ samples: inout [Sample]) -> Summary? {
        guard !samples.isEmpty else { return nil }
        defer { samples.removeAll(keepingCapacity: true) }
        return Summary(
            count: samples.count,
            toFeedback: Percentiles(samples.map(\.toFeedback)),
            toEcho: Percentiles(samples.map(\.toEcho)),
            keyToSent: Percentiles(samples.map(\.keyToSent)),
            sentToOutput: Percentiles(samples.map(\.sentToOutput)),
            outputToFrame: Percentiles(samples.map(\.outputToFrame)),
            frameToScreen: Percentiles(samples.map(\.frameToScreen)))
    }
}

/// Rounded to the microsecond, so sums of float seconds compare as written.
private func milliseconds(from start: Double, to end: Double) -> Double {
    ((end - start) * 1_000_000).rounded() / 1000
}
