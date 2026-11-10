import DesignSystem
import GudoCore
import HostKit
import SwiftUI

struct AgentPowerSettings: View {
    private let hosts = AppModel.shared.hosts

    var body: some View {
        Section {
            ForEach(DeviceHosts.owned(hosts), id: \.id) { host in
                if let connection = hosts.connection(host.id) as? DaemonConnection {
                    HostPowerSetting(name: host.name, connection: connection)
                }
            }
        } header: {
            Text("Keep hosts awake while agents work")
        } footer: {
            Text("The display can sleep and lock. Closing a laptop's lid can still put it to sleep.")
        }
        .settingAnchor("agent-power")
    }
}

private struct HostPowerSetting: View {
    let name: String
    let connection: DaemonConnection
    @State private var status: PowerStatus?
    @State private var failure: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let status {
                PowerPolicyControl(name: name, policy: Binding(get: { status.policy }, set: { policy in
                    isSaving = true
                    Task {
                        defer { isSaving = false }
                        do {
                            self.status = try await connection.powerSettings(policy: policy)
                            failure = nil
                        } catch { failure = error.localizedDescription }
                    }
                }), keepingAwake: status.keepingAwake)
                .disabled(isSaving)
            } else {
                LabeledContent(name, value: failure ?? "Connecting…")
            }
            if status != nil, let failure {
                Text(failure).font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.error)
            }
        }
        .task(id: connection.isReady) {
            guard connection.isReady else { return }
            do { status = try await connection.powerSettings() }
            catch { failure = error.localizedDescription }
        }
    }
}

struct PowerPolicyControl: View {
    let name: String
    @Binding var policy: PowerPolicy
    let keepingAwake: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Picker(name, selection: $policy) {
                Text("Always").tag(PowerPolicy.always)
                Text("When Plugged In").tag(PowerPolicy.whenPluggedIn)
                Text("Never").tag(PowerPolicy.never)
            }
            .accessibilityIdentifier("agent-power-policy")
            if keepingAwake {
                Label("Keeping awake while agents work", systemImage: "sun.max")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }
}

struct AgentPowerStatus: View {
    private let hosts = AppModel.shared.hosts
    @State private var awakeHosts: [String] = []
    /// A host keeps itself awake for as long as its agents work: minutes, so this need not be quick.
    private static let refreshInterval = Duration.seconds(15)

    var body: some View {
        Group {
            if !awakeHosts.isEmpty {
                Label("Keeping awake: \(awakeHosts.joined(separator: ", "))", systemImage: "sun.max")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityIdentifier("agents-keeping-awake")
            }
        }
        .task {
            while !Task.isCancelled {
                var awake: [String] = []
                for host in DeviceHosts.owned(hosts) {
                    guard let connection = hosts.connection(host.id) as? DaemonConnection,
                          connection.isReady, !connection.isLowDataMode else { continue }
                    if let status = try? await connection.powerSettings(), status.keepingAwake {
                        awake.append(host.name)
                    }
                }
                awakeHosts = awake
                do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            }
        }
    }
}
