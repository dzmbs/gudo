import DesignSystem
import GudoCore
import HostKit
import PaneLayout
import SwiftUI

struct PaneSizingOverlay: View {
    let pane: Pane
    let workspace: Workspace
    @Environment(WindowModel.self) private var model
    @State private var shown: PaneSizingSource?

    var body: some View {
        if let daemon = workspace.host as? DaemonConnection {
            let source = source(in: daemon)
            ZStack(alignment: .top) {
                if let shown, shown == source, !pane.showsSavedScreen, pane.connection == .live {
                    PaneSizingChip(label: label(for: shown, in: daemon), enabled: canUseSize(in: daemon)) {
                        (pane.backend as? any SharedPaneTap)?.useSize()
                    }
                    .motionTransition(.panel(from: .top))
                }
            }
            .task(id: source) {
                guard source != nil else { shown = nil; return }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                shown = source
            }
        }
    }

    private func source(in daemon: DaemonConnection) -> PaneSizingSource? {
        _ = pane.resizesSent
        guard daemon.status.isLive, let state = daemon.sizing[pane.id],
              let metadata = daemon.meta[pane.id], let grid = pane.view.surface.grid else { return nil }
        let session = daemon.multiplayer
        let matchesOwnGrid = grid.cols == metadata.size.cols && grid.rows == metadata.size.rows
        return PaneSizingSource.resolve(state, myPeer: session.myPeer, policy: metadata.sizePolicy, isLocalDriver: pane.isSizingTap,
                                        othersConnected: session.peers.keys.contains { $0 != session.myPeer },
                                        matchesOwnGrid: matchesOwnGrid)
    }

    private func canUseSize(in daemon: DaemonConnection) -> Bool {
        let session = daemon.multiplayer
        let gate = session.inputGate
        return model.reportedSizingActivity == .active && session.me != nil
            && session.canDrive && !gate.all && !gate.panes.contains(pane.id.rawValue)
    }

    private func label(for source: PaneSizingSource, in daemon: DaemonConnection) -> String {
        switch source {
        case .anotherWindow: return "Sized for another window"
        case .fixed: return "Fixed size"
        case .shared: return "Shared size"
        case .peer(let id):
            let session = daemon.multiplayer
            guard let peer = session.peers[id] else { return "Sized for another device" }
            // The name the owner gave the device in its list, else the one it gave itself.
            let listed = session.devices.first { $0.device == peer.actor.device }?.name
            let myDevice = session.myPeer.flatMap { session.peers[$0]?.device }
            return PaneSizingSource.peerLabel(name: listed ?? peer.name, device: peer.device, myDevice: myDevice)
        }
    }
}

struct PaneSizingChip: View {
    let label: String
    let enabled: Bool
    let useSize: () -> Void

    private var controlHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    /// A header strip along the pane's top edge: the terminal's own input lines stay clear.
    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(DS.Palette.textSecondary)
            Spacer(minLength: 0)
            Button(action: useSize) {
                Text("Use this size")
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: controlHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Palette.text)
            .disabled(!enabled)
            .accessibilityIdentifier("terminal-sizing-takeover")
            .accessibilityHint("Makes this window set the shared terminal size.")
        }
        .font(DS.Font.meta)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(DS.Palette.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.hairline).frame(height: 1).allowsHitTesting(false)
        }
    }
}
