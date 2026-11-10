#if os(iOS)
import HostKit
import PaneLayout
import UIKit

extension Workspace {
    func updateChatState(of pane: Pane) {
        let connection = host as? DaemonConnection
        let reported = connection?.meta[pane.id]?.agent?.kind
        guard let kind = reported.flatMap(AgentKind.init(rawValue:)) else {
            pane.chat?.updateAgent(nil)
            return
        }
        let offersChat = connection?.workspace.offersAgentTimeline == true
        let state: PaneChatState
        if let existing = pane.chat {
            if existing.offersChat != offersChat { existing.offersChat = offersChat }
            guard existing.agent != kind else { return }
            state = existing
            state.updateAgent(kind)
        } else {
            state = PaneChatState(member: HostPane(hostId: groupId, pane: pane.id),
                                  defaultPresentation: UIDevice.current.userInterfaceIdiom == .phone && offersChat
                                    ? .chat : .terminal,
                                  agent: kind, offersChat: offersChat, inputPresentation: pane.inputPresentation)
            pane.chat = state
        }
        // Before a host container can lay out: hidden Chat geometry must not win a size claim.
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
    }
}
#endif
