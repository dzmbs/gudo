import GudoCore

nonisolated public protocol PowerSettingsClient: AnyObject, Sendable {
    func powerSettings(policy: PowerPolicy?) async throws -> PowerStatus
}

extension DaemonClient: PowerSettingsClient {}

extension DaemonConnection {
    public func powerSettings(policy: PowerPolicy? = nil) async throws -> PowerStatus {
        guard let client = client as? any PowerSettingsClient else { throw HostError.notConnected }
        return try await client.powerSettings(policy: policy)
    }
}
