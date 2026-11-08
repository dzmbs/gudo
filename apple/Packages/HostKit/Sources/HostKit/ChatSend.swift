import Foundation

nonisolated public struct ChatSendOffer: Decodable, Equatable, Sendable {
    public let ticket: UInt64
    public let revision: UInt64
    public let needsConfirmation: Bool

    public init(ticket: UInt64, revision: UInt64, needsConfirmation: Bool) {
        self.ticket = ticket
        self.revision = revision
        self.needsConfirmation = needsConfirmation
    }

    private enum CodingKeys: String, CodingKey {
        case ticket, revision
        case needsConfirmation = "needs_confirmation"
    }
}

nonisolated public enum ChatSendStatus: Decodable, Equatable, Sendable {
    case prepared(ChatSendOffer), confirmationRequired(UInt64), confirmed, notConfirmed, sentNotConfirmed, interruptRequested

    private enum Keys: String, CodingKey { case prepared = "Prepared", confirmation = "ConfirmationRequired", revision }

    public init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "Confirmed": self = .confirmed
            case "NotConfirmed": self = .notConfirmed
            case "SentNotConfirmed": self = .sentNotConfirmed
            case "InterruptRequested": self = .interruptRequested
            default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown send receipt"))
            }
        } else {
            let values = try decoder.container(keyedBy: Keys.self)
            if values.contains(.prepared) {
                self = .prepared(try values.decode(ChatSendOffer.self, forKey: .prepared))
            } else {
                let confirmation = try values.nestedContainer(keyedBy: Keys.self, forKey: .confirmation)
                self = .confirmationRequired(try confirmation.decode(UInt64.self, forKey: .revision))
            }
        }
    }

    public static func decode(_ json: String) throws -> Self {
        guard json.utf8.count <= 1_024 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Oversized send receipt"))
        }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}
