import HostKit
import PaneLayout
import SwiftUI
import UnnamedCore
#if canImport(UIKit)
import UIKit
#endif

/// Keeps a window's live presence in step with the host, ten times a second: reports where this
/// device looks (the focused pane's scroll position), and while following someone moves the
/// window to their pane and scroll position. Any move of your own (another pane or tab, a scroll,
/// a key) stops following.
@MainActor
final class PresenceSync {
    private let workspace: Workspace
    /// The pane following last put in focus, to tell the user's own moves from ours.
    private var followedFocus: PaneId?
    /// That pane's `moves` after following's own last scroll; any other count is the user's.
    private var followedMoves: Int?
    /// The leader's viewport last applied, so their every scroll is applied once.
    private var appliedViewport: PeerViewport?
    private var leaderPeer: UInt64?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func run() async {
        while !Task.isCancelled {
            step()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func step() {
        guard let session = workspace.multiplayer, session.me != nil, session.hasLivePresence else { return }
        follow(session)
        session.setViewport(viewport(of: workspace.focusedPane))
    }

    /// The focused pane's rows on screen, counted from the live screen up.
    private func viewport(of pane: PaneId?) -> PeerViewport? {
        guard let pane, let view = workspace.pane(pane)?.view else { return nil }
        let bar = view.surface.terminal.scrollbar
        let fromBottom = max(0, bar.total - bar.offset - bar.visible)
        return PeerViewport(paneId: pane.rawValue, fromBottom: UInt32(fromBottom), rows: UInt16(clamping: bar.visible))
    }

    private func follow(_ session: MultiplayerSession) {
        guard session.following != nil else {
            followedFocus = nil
            followedMoves = nil
            appliedViewport = nil
            return
        }
        // Moved by hand: stop following, as Zed and Figma do.
        if let followedFocus,
           workspace.focusedPane != followedFocus || workspace.pane(followedFocus)?.moves != followedMoves {
            session.breakFollow()
            self.followedFocus = nil
            followedMoves = nil
            return
        }
        guard let leader = session.leaderPeer, let focus = leader.focus else { return }
        let pane = PaneId(focus)
        guard workspace.session.panes.contains(pane) else { return }
        if leader.peer != leaderPeer {
            leaderPeer = leader.peer
            appliedViewport = nil
        }
        if workspace.focusedPane != pane {
            workspace.apply(.focus(pane))
        }
        followedFocus = pane
        if let target = leader.viewport, target.paneId == focus, target != appliedViewport,
           let view = workspace.pane(pane)?.view {
            appliedViewport = target
            let current = viewport(of: pane)?.fromBottom ?? 0
            let delta = Int(current) - Int(target.fromBottom)
            if delta != 0 { view.surface.scroll(rows: delta) }
        }
        followedMoves = workspace.pane(pane)?.moves
    }
}

/// Runs a window's `PresenceSync` and says when the app leaves the foreground.
struct PresenceSyncModifier: ViewModifier {
    let workspace: Workspace
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: ObjectIdentifier(workspace)) {
                guard !LaunchOptions.mock else { return }
                MultiplayerSession.deviceClass = Self.deviceClass
                workspace.multiplayer?.announceDevice()
                await PresenceSync(workspace: workspace).run()
            }
            .onChange(of: scenePhase) { _, phase in
                workspace.multiplayer?.setAway(phase == .background)
            }
    }

    private static var deviceClass: DeviceClass {
        #if os(macOS)
        .desktop
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        #endif
    }
}
