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
            ZStack(alignment: .bottomTrailing) {
                if let shown, shown == source, !pane.showsSavedScreen, pane.connection == .live {
                    PaneSizingChip(label: label(for: shown, in: daemon), enabled: canUseSize(in: daemon)) {
                        (pane.backend as? any SharedPaneTap)?.useSize()
                    }
                    .padding(8)
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
              let metadata = daemon.meta[pane.id], pane.view.surface.grid != nil else { return nil }
        return PaneSizingSource.resolve(state, myPeer: daemon.multiplayer.myPeer,
                                        policy: metadata.sizePolicy, isLocalDriver: pane.isSizingTap)
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
            guard let peer = daemon.multiplayer.peers[id] else { return "Sized for another device" }
            let name: String
            switch peer.device {
            case .phone: name = "iPhone"
            case .tablet: name = "iPad"
            case .desktop: name = "Mac"
            case .terminal, .unknown: name = peer.name.isEmpty ? "another device" : peer.name
            }
            return "Sized for \(name)"
        }
    }
}

struct PaneSizingChip: View {
    let label: String
    let enabled: Bool
    let useSize: () -> Void
    @Environment(\.terminalTheme) private var theme

    private var controlHeight: CGFloat {
        #if os(macOS)
        28
        #else
        44
        #endif
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label + " ·")
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: useSize) {
                Text("Use this size")
                    .underline()
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: controlHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityIdentifier("terminal-sizing-takeover")
            .accessibilityHint("Makes this window set the shared terminal size.")
        }
        .font(DS.Font.meta)
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 10)
        .background(theme.background, in: .capsule)
        .overlay { Capsule().strokeBorder(theme.foreground.opacity(0.2), lineWidth: 1).allowsHitTesting(false) }
    }
}
