import DesignSystem
import HostKit
import SwiftUI

/// Settings ▸ Agents: the browser and drawings tools (the host's MCP server) for agents the user
/// starts by typing `claude` or `codex` in a pane, not only those started with New Agent. Off by
/// default: turning it on or off runs each vendor's own `mcp add` / `mcp remove` on the
/// connected hosts, shown first and run in a terminal tab where the user sees it.
struct AgentToolsSection: View {
    static let key = "agentToolsInTerminals"
    @AppStorage(Self.key) private var isOn = false
    @State private var change: Bool?

    var body: some View {
        Section {
            Toggle("Browser and Drawings for Agents Started in a Terminal", isOn: Binding(
                get: { isOn }, set: { change = $0 }))
                .accessibilityIdentifier("settings-agent-tools")
                .settingAnchor("agent-tools")
        } header: {
            Text("Agent Tools")
        } footer: {
            Text("""
            Agents started with New Agent always get the browser and drawings tools. This also adds \
            them to Claude Code and Codex on your hosts with their own `mcp add` command, so sessions \
            you start by typing `claude` or `codex` get them too. You see the commands before they run.
            """)
        }
        .sheet(item: Binding(get: { change.map(Change.init) }, set: { change = $0?.register })) { change in
            AgentToolsSheet(register: change.register) { isOn = change.register }
        }
    }

    private struct Change: Identifiable {
        let register: Bool
        var id: Bool { register }
    }
}

/// What turning the tools on or off runs on each connected host, run on confirmation in a new
/// tab there.
private struct AgentToolsSheet: View {
    let register: Bool
    let applied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var plans: [Plan]?
    @State private var failure: String?

    struct Plan: Identifiable {
        let hostId: String
        let name: String
        /// The shell line, nil when there is nothing to run there (`note` says why).
        let command: String?
        let note: String?
        var id: String { hostId }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let plans {
                        if plans.isEmpty {
                            Text("No host is connected.").foregroundStyle(DS.Palette.textSecondary)
                        }
                        ForEach(plans) { plan in
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Label(plan.name, systemImage: "server.rack")
                                    .font(DS.Font.rowTitleEmphasis)
                                if let command = plan.command {
                                    Text(verbatim: command)
                                        .font(DS.Font.literalSmall)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("agent-tools-command")
                                }
                                if let note = plan.note {
                                    Text(note)
                                        .font(DS.Font.rowSubtitle)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                            }
                            .padding(.vertical, DS.Space.xs)
                        }
                    } else {
                        Spinner().frame(width: 16, height: 16)
                    }
                } footer: {
                    Text(register
                        ? "Each runs in a new terminal tab on its host. Turning this off removes them the same way."
                        : "Each runs in a new terminal tab on its host.")
                }
                if let failure {
                    Text(failure).foregroundStyle(DS.Palette.error)
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .navigationTitle(register ? "Add Agent Tools" : "Remove Agent Tools")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { run() }
                        .disabled(plans?.contains { $0.command != nil } != true)
                        .accessibilityIdentifier("agent-tools-run")
                }
            }
        }
        .macMinimumSize(width: 560, height: 360)
        .task { plans = await Self.plans(register: register) }
    }

    /// Each connected host's commands, asked of its helper.
    private static func plans(register: Bool) async -> [Plan] {
        let hosts = AppModel.shared.hosts
        var plans: [Plan] = []
        for (id, connection) in hosts.connections.sorted(by: { $0.key < $1.key }) {
            guard let daemon = connection as? DaemonConnection, daemon.isReady else { continue }
            let name = hosts.record(id)?.name ?? id
            guard daemon.daemonInfo?.agentMcp == true,
                  let api = try? daemon.workspace.client() as? DaemonAgentInstallAPI
            else {
                plans.append(Plan(hostId: id, name: name, command: nil, note: "Update the helper on this host first."))
                continue
            }
            do {
                let commands = try await api.agentMcpCommands(register: register)
                let line = commands.map { $0.argv.map(ShellWord.quote).joined(separator: " ") }.joined(separator: "; ")
                plans.append(Plan(
                    hostId: id, name: name, command: line.isEmpty ? nil : line,
                    note: line.isEmpty ? "Neither Claude Code nor Codex is installed here." : nil))
            } catch {
                plans.append(Plan(hostId: id, name: name, command: nil, note: ScreenError.describe(error)))
            }
        }
        return plans
    }

    private func run() {
        let runs = (plans ?? []).compactMap { plan in plan.command.map { (plan.hostId, $0) } }
        let title = register ? "Add Agent Tools" : "Remove Agent Tools"
        Task {
            for (hostId, command) in runs {
                guard let daemon = AppModel.shared.hosts.connection(hostId) as? DaemonConnection,
                      let session = daemon.layout.sessionId else { continue }
                do {
                    let pane = try await daemon.workspace.repoClient().scriptRun(cwd: "~", sessionId: session, name: title, command: command)
                    ActiveWindow.model?.reveal(host: hostId, pane: pane)
                } catch {
                    failure = ScreenError.describe(error)
                    return
                }
            }
            applied()
            dismiss()
        }
    }
}

/// One word for a POSIX shell, quoted only when it needs to be.
nonisolated enum ShellWord {
    static func quote(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:,@")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
