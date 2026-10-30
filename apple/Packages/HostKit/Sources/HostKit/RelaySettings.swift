import Foundation
import Security
import UnnamedCore

/// How this device reaches its daemons (docs/RELAYS.md): the way each host's pairing ticket
/// says, direct only (LAN, Tailscale, VPN: no relay, no third party), or through the user's
/// own `iroh-relay`; plus private CA certificates that self-hosted relays chain to.
///
/// Saved as `relay-settings.json` next to `hosts.json`; the relay's access token lives in the
/// secret store.
nonisolated public struct RelaySettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Follow each host's ticket (the product's relays, the host's own, or none).
        case automatic
        /// No relay for any host: direct addresses only.
        case directOnly
        /// Every host through `customURL`.
        case custom

        public var id: String { rawValue }
    }

    public var mode: Mode = .automatic
    /// The relay for `.custom`, as typed (`RelayURL.parse` checks it).
    public var customURL = ""
    /// The relay's shared token (`access.shared_token`), if it needs one. Not in the JSON.
    public var authToken = ""
    /// Extra trust roots (DER) for relays with a private CA. The usual web roots stay trusted.
    public var certificates: [Data] = []

    public init(mode: Mode = .automatic, customURL: String = "", authToken: String = "", certificates: [Data] = []) {
        self.mode = mode
        self.customURL = customURL
        self.authToken = authToken
        self.certificates = certificates
    }

    private enum CodingKeys: String, CodingKey {
        case mode, customURL, certificates
    }

    /// The custom relay when it is the mode and its URL is valid.
    public var customRelay: URL? {
        guard mode == .custom else { return nil }
        return try? RelayURL.parse(customURL)
    }

    /// The relay mode for `ClientConfig`: direct only wins over everything, including what a
    /// ticket asks for; `base` is the app's launch configuration (tests force `.disabled`).
    public func clientRelay(base: RelayMode = .default) -> RelayMode {
        base == .disabled || mode == .directOnly ? .disabled : .default
    }

    /// `ConnectOptions` for every daemon connection: the private CAs, and the device's own
    /// relay in place of the ticket's. The app shows password prompts, opens URLs for the host
    /// and shows what programs in panes report (`askpass`, `browser`, `programStatus`).
    ///
    /// A guest (someone else's host) never gets `browser`: that host's programs and agents
    /// would open pages and drive this device's browser.
    public func connectOptions(askpass: Bool, guest: Bool = false) -> ConnectOptions {
        let relay = customRelay
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectOptions(
            relayCaDer: certificates,
            relayUrls: relay.map { [$0.absoluteString] } ?? [],
            relayAuthToken: relay != nil && !token.isEmpty ? token : nil,
            askpass: askpass,
            browser: askpass && !guest,
            programStatus: askpass)
    }

    /// Which relay a host whose ticket says `ticket` is reached through, in words (the pairing
    /// sheet), and whether this device's setting decided it rather than the ticket.
    public func relay(for ticket: TicketRelays) -> (name: String, bySetting: Bool) {
        if case .disabled = ticket { return ("None, direct only", false) }
        if mode == .directOnly { return ("None, direct only", true) }
        if let customRelay { return (customRelay.host() ?? customRelay.absoluteString, true) }
        switch ticket {
        case .default, .disabled:
            return ("Default", false)
        case .custom(let urls, _):
            let hosts = urls.map { URL(string: $0)?.host() ?? $0 }
            return (ListFormatter.localizedString(byJoining: hosts), false)
        }
    }

    // MARK: Persistence

    static let fileName = "relay-settings.json"
    static let tokenKey = "relay-auth-token"

    /// The saved settings (defaults when nothing was saved or the file does not read).
    public static func load(directory: URL, secrets: any SecretStore) -> RelaySettings {
        var settings = (try? Data(contentsOf: directory.appending(path: fileName)))
            .flatMap { try? JSONDecoder().decode(RelaySettings.self, from: $0) } ?? RelaySettings()
        settings.authToken = (try? secrets.string(for: tokenKey)) ?? ""
        return settings
    }

    public func save(directory: URL, secrets: any SecretStore) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
        if authToken.isEmpty {
            try secrets.remove(Self.tokenKey)
        } else {
            try secrets.set(authToken, for: Self.tokenKey)
        }
    }
}

/// A relay URL as the user types it: `relay.example.com` means `https://relay.example.com`.
nonisolated public enum RelayURL {
    public enum Problem: Error, Equatable, LocalizedError {
        case empty
        case scheme(String)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter the relay's address."
            case .scheme(let scheme): "Relays use https:// (or http:// for a test relay), not \(scheme)://."
            case .malformed: "That isn't a relay address. Use one like https://relay.example.com."
            }
        }
    }

    public static func parse(_ text: String) throws(Problem) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme), let scheme = components.scheme?.lowercased() else {
            throw .malformed
        }
        guard scheme == "https" || scheme == "http" else { throw .scheme(scheme) }
        guard let host = components.host, !host.isEmpty, !host.contains(" "),
              components.query == nil, components.fragment == nil, components.user == nil,
              let url = components.url
        else { throw .malformed }
        return url
    }
}

/// A CA certificate the user imported for a self-hosted relay.
nonisolated public struct RelayCertificate: Equatable, Sendable, Identifiable {
    public let der: Data
    /// The subject's summary (usually the common name).
    public let subject: String
    public let expires: Date?

    public var id: Data { der }

    public var isExpired: Bool { expires.map { $0 < Date() } ?? false }

    public enum Problem: Error, Equatable, LocalizedError {
        case notACertificate
        case privateKey
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .notACertificate: "The file holds no certificate. Choose a .pem, .crt or .cer file."
            case .privateKey: "The file holds a private key. Choose the CA's certificate instead; the key stays on the relay."
            case .unreadable(let file): "\(file) could not be read."
            }
        }
    }

    public init?(der: Data) {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        self.der = der
        subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Certificate"
        expires = SecCertificateCopyNotValidAfterDate(certificate) as Date?
    }

    /// Every certificate in a PEM file (one or more `BEGIN CERTIFICATE` blocks) or a DER file.
    public static func parse(_ data: Data) throws(Problem) -> [RelayCertificate] {
        let blocks = pemBlocks(data)
        if blocks.isEmpty {
            // DER: an ASN.1 SEQUENCE.
            if data.first == 0x30, let certificate = RelayCertificate(der: data) { return [certificate] }
            if let text = String(data: data, encoding: .utf8), text.contains("PRIVATE KEY-----") { throw .privateKey }
            throw .notACertificate
        }
        let certificates = blocks.compactMap(RelayCertificate.init(der:))
        guard !certificates.isEmpty else { throw .notACertificate }
        return certificates
    }

    /// The base64 bodies of `-----BEGIN CERTIFICATE-----` blocks, decoded.
    static func pemBlocks(_ data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        var blocks: [Data] = []
        var rest = Substring(text)
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex) {
            let body = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)) { blocks.append(der) }
            rest = rest[stop.upperBound...]
        }
        return blocks
    }
}
