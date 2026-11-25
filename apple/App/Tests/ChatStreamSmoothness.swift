import Foundation
import XCTest

/// A reproducible lumpy stream: every `gap` a burst of 1 to 40 words, its size from a seeded
/// hash, as a fast model's tokens arrive through the helper's coalescing window.
nonisolated struct BurstyStream {
    static let gap: Duration = .milliseconds(90)
    private static let words = ["the", "reply", "streams", "in", "uneven", "bursts,", "and", "each", "one", "lands",
                                "as", "a", "single", "update;", "pacing", "keeps", "what", "shows", "growing", "evenly."]
    private var state: UInt64
    private var word = 0

    init(seed: UInt64) { state = seed }

    /// The next burst's text.
    mutating func burst() -> String {
        let count = 1 + Int(next() % 40)
        var text = ""
        for _ in 0..<count {
            text += " " + Self.words[word % Self.words.count]
            word += 1
        }
        return text
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// How evenly a streaming reply grew on screen: the coefficient of variation of characters
/// shown per 60 Hz frame (smoothness) and the gaps between frames that showed more (stalls).
/// Both are needed: a stalled stream is perfectly smooth.
nonisolated struct StreamSmoothness: CustomStringConvertible {
    static let frame: Duration = .microseconds(16_667)
    static let maximumCoefficientOfVariation = 2.0
    static let maximumGapP95: Duration = .milliseconds(34)

    let coefficientOfVariation: Double
    let gapP50: Duration
    let gapP95: Duration
    let visibleUpdates: Int
    let characters: Int

    init(samples: [(time: ContinuousClock.Instant, length: Int)]) {
        var updates: [(time: ContinuousClock.Instant, added: Int)] = []
        var shown = samples.first?.length ?? 0
        for sample in samples.dropFirst() where sample.length > shown {
            updates.append((sample.time, sample.length - shown))
            shown = sample.length
        }
        visibleUpdates = updates.count
        characters = updates.reduce(0) { $0 + $1.added }
        let gaps = zip(updates, updates.dropFirst()).map { $0.time.duration(to: $1.time) }.sorted()
        gapP50 = gaps.isEmpty ? .zero : gaps[gaps.count / 2]
        gapP95 = gaps.isEmpty ? .zero : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
        guard let first = updates.first?.time, let last = updates.last?.time else {
            coefficientOfVariation = 0
            return
        }
        let frames = max(1, Int((first.duration(to: last) / Self.frame).rounded(.down)) + 1)
        var perFrame = [Double](repeating: 0, count: frames)
        for update in updates {
            let index = min(frames - 1, Int((first.duration(to: update.time) / Self.frame).rounded(.down)))
            perFrame[index] += Double(update.added)
        }
        let mean = perFrame.reduce(0, +) / Double(frames)
        let variance = perFrame.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(frames)
        coefficientOfVariation = mean > 0 ? variance.squareRoot() / mean : 0
    }

    var description: String {
        String(format: "%d characters in %d visible updates, chars-per-frame CV %.2f, gap p50 %@, p95 %@",
               characters, visibleUpdates, coefficientOfVariation, gapP50.formattedMilliseconds, gapP95.formattedMilliseconds)
    }

    func check(label: String, file: StaticString = #filePath, line: UInt = #line) {
        print("chat-smoothness \(label): \(self)")
        XCTAssertGreaterThan(visibleUpdates, 20, "\(label): the reply barely grew", file: file, line: line)
        XCTAssertLessThanOrEqual(coefficientOfVariation, Self.maximumCoefficientOfVariation, "\(label): chars-per-frame CV",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(gapP95, Self.maximumGapP95, "\(label): p95 gap between visible updates", file: file, line: line)
    }
}
