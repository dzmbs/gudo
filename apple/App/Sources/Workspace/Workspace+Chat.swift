import HostKit
import PaneLayout
#if canImport(UIKit)
import UIKit
#endif

extension Workspace {
    func updateChatState(of pane: Pane) {
        let connection = host as? DaemonConnection
        let reported = connection?.meta[pane.id]?.agent?.kind
        guard let kind = reported.flatMap(AgentKind.init(rawValue:)) else {
            pane.chat?.updateAgent(nil)
            return
        }
        let offersChat = connection?.workspace.offersAgentTimeline == true
            && (kind != .pi || connection?.workspace.offersPiChat == true)
        let state: PaneChatState
        if let existing = pane.chat {
            if existing.offersChat != offersChat { existing.offersChat = offersChat }
            guard existing.agent != kind else { return }
            state = existing
            state.updateAgent(kind)
        } else {
            state = PaneChatState(member: HostPane(hostId: groupId, pane: pane.id),
                                  defaultPresentation: Self.defaultChatPresentation(offersChat: offersChat),
                                  agent: kind, offersChat: offersChat, inputPresentation: pane.inputPresentation)
            pane.chat = state
        }
        // Before a host container can lay out: hidden Chat geometry must not win a size claim.
        state.prepareInitialPresentation { pane.prepareToParkTerminal() }
    }

    /// The Chat of the tab's only pane when it runs an agent: the title bar carries its switch,
    /// as a split pane's header does.
    var soleAgentPaneChat: (pane: Pane, chat: PaneChatState)? {
        guard session.activeTab?.root.panes.count == 1, let id = focusedPane, let pane = panes[id],
              let chat = pane.chat, chat.agent != nil else { return nil }
        return (pane, chat)
    }

    /// An agent pane opens in Chat on the iPhone; the iPad and the Mac open its terminal until
    /// the user picks Chat.
    static func defaultChatPresentation(offersChat: Bool) -> PanePresentation {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone && offersChat ? .chat : .terminal
        #else
        .terminal
        #endif
    }
}
