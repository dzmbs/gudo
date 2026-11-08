import Foundation

nonisolated public struct AgentCapabilities: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let read = Self(rawValue: 1 << 0)
    public static let send = Self(rawValue: 1 << 1)
    public static let acknowledgedSend = Self(rawValue: 1 << 2)
    public static let stop = Self(rawValue: 1 << 3)
    public static let approvals = Self(rawValue: 1 << 4)
    public static let diffs = Self(rawValue: 1 << 5)
    public static let streamingDeltas = Self(rawValue: 1 << 6)
    public static let thinking = Self(rawValue: 1 << 7)
    public static let plans = Self(rawValue: 1 << 8)

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UInt16.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}
