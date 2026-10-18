import Foundation
import UnnamedCore

/// This device's identity: the 32-byte Ed25519 key every daemon allowlists on pairing
/// (docs/DAEMON.md "Identity and pairing"). Generated once and kept in the secret store.
nonisolated public enum DeviceIdentity {
    static let key = "device-key"

    /// The device key, generated and stored on first use.
    public static func load(from store: any SecretStore) throws -> Data {
        if let existing = try store.data(for: key), existing.count == 32 { return existing }
        let fresh = generateDeviceKey()
        try store.set(fresh, for: key)
        return fresh
    }
}

/// A pairing ticket as the user hands it over: pasted text, a scanned QR code (upper-cased
/// by `unnamed-hostd pair`'s terminal QR), or a deep link `<scheme>://pair/<ticket>`.
nonisolated public struct PairingTicket: Sendable, Equatable {
    /// The ticket in the form `DaemonClient.connect` takes.
    public let text: String
    public let info: PairTicketInfo

    /// Parses whatever the user gave us. Accepts surrounding whitespace and line breaks
    /// (terminals wrap long tickets), any case, the URL form or the bare payload.
    public init(_ input: String) throws(HostError) {
        let compact = input.filter { !$0.isWhitespace }
        do {
            info = try inspectPairTicket(ticket: compact)
        } catch {
            throw .badTicket(String(describing: error))
        }
        text = compact
    }

    /// A deep link (`unnamed://pair/…`), or nil if the URL is not a pairing link.
    public init?(url: URL) {
        guard url.host() == "pair" || url.absoluteString.lowercased().contains("://pair/"),
              let ticket = try? PairingTicket(url.absoluteString)
        else { return nil }
        self = ticket
    }

    /// A short, stable name for a host known only by its ticket.
    public var defaultName: String {
        "Host \(info.daemonId.prefix(8))"
    }

    public var isExpired: Bool {
        Date(timeIntervalSince1970: Double(info.expiresUnixMs) / 1000) < Date()
    }
}
