#if os(macOS)
import DesignSystem
import ServiceManagement
import SwiftUI

/// Settings ▸ This Mac: the helper that gives This Mac files, changes, ports, the editor and
/// agents, whether its sessions keep running after the app quits, and stopping it.
struct ThisMacSettingsSection: View {
    private let helper = AppModel.shared.localHelper
    @State private var keepsRunning = true
    @State private var commandLineTool = CommandLineTool.Status.notInstalled

    var body: some View {
        if let helper {
            Section {
                LabeledContent("Helper") {
                    Text(status(helper)).foregroundStyle(DS.Palette.textSecondary)
                }
                .accessibilityIdentifier("settings-this-mac-status")
                Toggle("Keep Sessions Running in the Background", isOn: $keepsRunning)
                    .disabled(!helper.isEnabled || helper.isIsolated)
                    .onChange(of: keepsRunning) { _, keep in
                        if keep != helper.keepsRunning { helper.setKeepsRunning(keep) }
                    }
                    .accessibilityIdentifier("settings-this-mac-keep-running")
                    .settingAnchor("this-mac-keep-running")
                if helper.needsApproval {
                    LabeledContent("Allow it in Login Items to keep sessions running after the app quits.") {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(DS.Font.rowDetail)
                }
                if CommandLineTool.helper != nil {
                    LabeledContent {
                        if commandLineTool == .installed {
                            Text("Installed").foregroundStyle(DS.Palette.textSecondary)
                        } else {
                            Button("Install…") {
                                CommandLineTool.installAndReport()
                                commandLineTool = CommandLineTool.status()
                            }
                            .accessibilityIdentifier("settings-this-mac-install-cli")
                        }
                    } label: {
                        Text("Command Line Tool")
                        Text("\(Brand.commandLineTool) pair and \(Brand.commandLineTool) devices in any terminal")
                    }
                    .settingAnchor("this-mac-command-line-tool")
                    .onAppear { commandLineTool = CommandLineTool.status() }
                }
                if helper.isEnabled && helper.state != .off {
                    Button("Stop Helper", role: .destructive) { helper.stop() }
                        .accessibilityIdentifier("settings-this-mac-stop")
                        .settingAnchor("this-mac-helper")
                } else if helper.binary != nil {
                    Button("Start Helper") { helper.enable() }
                        .accessibilityIdentifier("settings-this-mac-start")
                        .settingAnchor("this-mac-helper")
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text(footer(helper))
            }
            .onAppear { keepsRunning = helper.keepsRunning }
        }
    }

    private func status(_ helper: LocalHelper) -> String {
        switch helper.state {
        case .off: helper.binary == nil ? "Not included in this build" : "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .failed(let reason): reason
        }
    }

    private func footer(_ helper: LocalHelper) -> String {
        if helper.state == .off {
            return "Without the helper, This Mac has plain terminal tabs only: no files, changes, ports, editor or agents."
        }
        return keepsRunning
            ? "Terminals and agents on This Mac keep running when you quit, and come back when you open the app. Stop the helper to end them."
            : "Terminals and agents on This Mac end when you quit the app."
    }
}
#endif
