import Foundation
import HostKit
import GudoCore

/// What the app hands the File Provider extension, which runs without the app: the paired
/// hosts it may show (owner hosts only, never guests), their tickets, this device's key and
/// the relay settings. Files go to a folder in the shared App Group container, secrets to the
/// shared Keychain group. Builds without a team have neither (`FILES_PROVIDER = NO`).
nonisolated public struct FilesShare: Sendable {
    public let directory: URL
    public let secrets: any SecretStore

    static let deviceKey = "device-key"

    public init(directory: URL, secrets: any SecretStore) {
        self.directory = directory
        self.secrets = secrets
    }

    /// The share named by a bundle's `FilesAppGroup` / `FilesKeychainGroup` (unset, or a build
    /// setting left unexpanded, in builds without the groups: nil).
    public static func shared(bundle: Bundle = .main, service: String) -> FilesShare? {
        func value(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        }
        guard let group = value("FilesAppGroup"), let keychainGroup = value("FilesKeychainGroup"),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return FilesShare(
            directory: container.appending(path: "FilesProvider"),
            secrets: KeychainStore(service: service, accessGroup: keychainGroup))
    }

    private var repository: HostRepository { HostRepository(directory: directory) }

    // MARK: App side

    /// Shares the hosts Files may show and what dialling them takes; hosts no longer listed
    /// lose their ticket here. Returns the shared hosts (one Files location each).
    @discardableResult
    public func publish(hosts: [HostRecord], appSecrets: any SecretStore, relay: RelaySettings) throws -> [HostRecord] {
        var shared: [HostRecord] = []
        for host in hosts where host.kind == .daemon && !host.isGuest {
            guard let ticket = try appSecrets.string(for: host.ticketKey) else { continue }
            if try secrets.string(for: host.ticketKey) != ticket { try secrets.set(ticket, for: host.ticketKey) }
            shared.append(host)
        }
        let key = try DeviceIdentity.load(from: appSecrets)
        if try secrets.data(for: Self.deviceKey) != key { try secrets.set(key, for: Self.deviceKey) }
        for old in repository.load() where !shared.contains(where: { $0.id == old.id }) {
            try secrets.remove(old.ticketKey)
            try? FileManager.default.removeItem(at: hostDirectory(old.id))
        }
        try repository.save(shared)
        try relay.save(directory: directory, secrets: secrets)
        return shared
    }

    // MARK: Extension side

    public func hosts() -> [HostRecord] {
        repository.load()
    }

    /// One host's own folder: its identifier map, its downloads.
    public func hostDirectory(_ hostId: String) -> URL {
        directory.appending(path: "hosts/\(hostId)")
    }

    /// The host's identifier map, kept across launches of the extension.
    public func identifiers(for hostId: String) -> ItemIdentifiers {
        let folder = hostDirectory(hostId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return ItemIdentifiers(file: folder.appending(path: "identifiers.json"))
    }

    /// Dials a shared host as this device, with the app's relay settings.
    /// - Parameter relayBase: `.disabled` for tests on loopback daemons.
    public func connect(hostId: String, listener: any ClientEventListener, relayBase: RelayMode = .default) throws -> DaemonClient {
        guard let host = hosts().first(where: { $0.id == hostId }),
              let ticket = try secrets.string(for: host.ticketKey),
              let key = try secrets.data(for: Self.deviceKey)
        else { throw FilesShareError.notShared(hostId) }
        let relay = RelaySettings.load(directory: directory, secrets: secrets)
        let config = ClientConfig(secretKey: key, relay: relay.clientRelay(base: relayBase), mirrorVt: false)
        return try DaemonClient.connectWith(
            ticket: ticket, config: config, options: relay.connectOptions(askpass: false), listener: listener)
    }
}

public enum FilesShareError: Error, Equatable, LocalizedError {
    case notShared(String)

    public var errorDescription: String? {
        switch self {
        case .notShared: "Open the app once to show this host in Files."
        }
    }
}

/// Which Files locations to add, update or remove for the shared hosts: one per host, named
/// after it.
nonisolated public enum DomainPlan {
    public struct Domain: Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// `add` holds new and renamed hosts (adding an existing identifier updates its name).
    public static func plan(existing: [Domain], hosts: [HostRecord]) -> (add: [Domain], remove: [String]) {
        let wanted = hosts.map { Domain(id: $0.id, name: $0.name) }
        let add = wanted.filter { !existing.contains($0) }
        let remove = existing.map(\.id).filter { id in !wanted.contains { $0.id == id } }
        return (add, remove)
    }
}
