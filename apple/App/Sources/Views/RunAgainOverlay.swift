import DesignSystem
import GudoCore
import HostKit
import PaneLayout
import SwiftUI

/// The command a restored pane was running when its host restarted, offered again at the
/// pane's bottom leading corner. It never runs by itself: a tap types it.
struct RunAgainOverlay: View {
    let pane: Pane
    let workspace: Workspace
    @State private var shown: RunAgainOffer?

    var body: some View {
        if let daemon = workspace.host as? DaemonConnection {
            let offer = offer(in: daemon)
            ZStack(alignment: .bottomLeading) {
                if let shown, shown == offer {
                    RunAgainChip(command: shown.command, enabled: daemon.multiplayer.canDrive) {
                        daemon.runAgain(in: pane.id)
                    }
                    .padding(8)
                }
            }
            .task(id: offer) {
                guard offer != nil else { shown = nil; return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                shown = offer
            }
        }
    }

    private func offer(in daemon: DaemonConnection) -> RunAgainOffer? {
        guard daemon.status.isLive, !pane.showsSavedScreen, pane.connection == .live else { return nil }
        return daemon.runAgain[pane.id]
    }
}

struct RunAgainChip: View {
    let command: String
    let enabled: Bool
    let run: () -> Void
    @Environment(\.terminalTheme) private var theme

    private var controlHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    var body: some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Text("Run again")
                    .underline()
                    .fixedSize()
                Text(command)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(theme.foreground.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minHeight: controlHeight)
            .padding(.horizontal, 10)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .font(DS.Font.meta)
        .foregroundStyle(theme.foreground)
        .background(theme.background, in: .capsule)
        .overlay { Capsule().strokeBorder(theme.foreground.opacity(0.2), lineWidth: 1).allowsHitTesting(false) }
        .accessibilityLabel("Run again: \(command)")
        .accessibilityHint("Types the command that was running before the restart.")
        .accessibilityIdentifier("terminal-run-again")
    }
}
