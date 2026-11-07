#if os(iOS)
import HostKit
import PaneLayout
import UIKit

extension Workspace {
    func updateChatState(of pane: Pane) {
        let reported = (host as? DaemonConnection)?.meta[pane.id]?.agent?.kind
        guard let kind = reported.flatMap(AgentKind.init(rawValue:)), kind != .other else {
            pane.chat?.updateAgent(nil)
            return
        }
        let state: PaneChatState
        if let existing = pane.chat {
            guard existing.agent != kind else { return }
            state = existing
            state.updateAgent(kind)
        } else {
            state = PaneChatState(member: HostPane(hostId: groupId, pane: pane.id),
                                  defaultPresentation: UIDevice.current.userInterfaceIdiom == .phone
                                    ? .chat : .terminal,
                                  agent: kind, inputPresentation: pane.inputPresentation)
            pane.chat = state
        }
        // Before a host container can lay out: hidden Chat geometry must not win a size claim.
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
    }
}
#endif
