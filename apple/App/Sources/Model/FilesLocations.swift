#if os(iOS) && FILES_PROVIDER_YES
import FileProvider
import FilesProviderKit
import HostKit
import Foundation
import os

/// Each paired host as a location in the Files app (the File Provider extension,
/// docs/APP-ARCHITECTURE.md §22): whenever the hosts or the relay settings change, what the
/// extension needs is shared and the locations follow. Only in builds with the shared groups.
@MainActor
enum FilesLocations {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "files")

    static func start(_ hosts: HostsModel) {
        guard let share = FilesShare.shared(service: (Bundle.main.object(forInfoDictionaryKey: "FilesSecretsService") as? String) ?? "secrets") else {
            log.error("Files locations: the build has no shared App Group or Keychain group")
            return
        }
        follow(hosts, share)
    }

    private static func follow(_ hosts: HostsModel, _ share: FilesShare) {
        let (records, relay) = withObservationTracking {
            (hosts.records, hosts.relaySettings)
        } onChange: {
            Task { @MainActor in follow(hosts, share) }
        }
        do {
            let shared = try share.publish(hosts: records, appSecrets: hosts.secrets, relay: relay)
            Task { await sync(shared) }
        } catch {
            log.error("Files locations: \(String(describing: error), privacy: .public)")
        }
    }

    private static func sync(_ shared: [HostRecord]) async {
        do {
            let existing = try await NSFileProviderManager.domains().map {
                DomainPlan.Domain(id: $0.identifier.rawValue, name: $0.displayName)
            }
            let plan = DomainPlan.plan(existing: existing, hosts: shared)
            for domain in plan.add {
                try await NSFileProviderManager.add(NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(domain.id), displayName: domain.name))
            }
            for id in plan.remove {
                try await NSFileProviderManager.remove(NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(id), displayName: ""))
            }
        } catch {
            log.error("Files locations: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
