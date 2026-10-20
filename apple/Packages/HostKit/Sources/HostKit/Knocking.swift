import Foundation
import os
import UnnamedCore

// Knock to join (docs/DAEMON.md §6.9): an invite whose owner wants to be asked first. The
// guest dials, waits while the owner decides, and on "Admit" gets a grant of its own, then
// joins like any invite.

/// Knocks with an invite and waits for the owner (`knockInvite`).
public typealias Knocker = @Sendable (
    _ invite: String, _ config: ClientConfig, _ options: ConnectOptions, _ name: String?, _ listener: any KnockListener
) async throws -> KnockResult

extension HostsModel {
    private static let knockLog = Logger(subsystem: Log.subsystem, category: "knock")

    /// Knocks with a knock invite and waits for the owner's answer, as long as it takes (cancel
    /// the task to stop waiting; the owner's request goes away). Once let in, joins with the
    /// grant the owner made for this device and returns the host id.
    ///
    /// - Parameter onWaiting: called once the owner has been asked.
    /// - Throws: `PairingError.turnedAway`, `KnockError` (unreachable, refused), or what
    ///   joining throws.
    @discardableResult
    public func knock(invite: String, name: String?, onWaiting: @escaping @Sendable () -> Void = {}) async throws -> String {
        let text = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ClientConfig(secretKey: try deviceKeyData(), relay: configuration.relay, mirrorVt: false)
        let options = ConnectOptions(relayCaDer: [], askpass: false)
        let knock = knocker ?? { invite, config, options, name, listener in
            try await knockInvite(invite: invite, config: config, options: options, name: name, listener: listener)
        }
        Self.knockLog.info("knocking")
        let result = try await knock(text, config, options, name, KnockRelay(onWaiting))
        switch result {
        case .admitted(let admitted):
            Self.knockLog.info("let in")
            return try await join(invite: admitted)
        case .denied:
            Self.knockLog.info("turned away")
            throw PairingError.turnedAway
        }
    }
}

/// Forwards "the owner has been asked" from the runtime thread.
nonisolated final class KnockRelay: KnockListener {
    private let handler: @Sendable () -> Void

    init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func onWaiting(knockId: UInt64) {
        handler()
    }
}
