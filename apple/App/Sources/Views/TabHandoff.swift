import Foundation
import Observation
import PaneLayout

/// The shown tab stays on top of a newly selected one until that has drawn its screen; the newest selection wins.
@Observable
final class TabHandoff {
    private(set) var shown: TabId?
    private(set) var incoming: TabId?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private let deadline: Duration

    /// About one display frame: readiness is a frame having been presented.
    static let checkInterval = Duration.milliseconds(4)

    init(deadline: Duration = .milliseconds(300)) {
        self.deadline = deadline
    }

    /// The tab selected now; `isReady` says whether its panes have presented their screens.
    func select(_ tab: TabId?, isReady: @escaping @MainActor () -> Bool) {
        guard tab != (incoming ?? shown) else { return }
        waiting?.cancel()
        waiting = nil
        incoming = nil
        guard let tab, shown != nil, tab != shown, !isReady() else {
            shown = tab
            if tab != nil { TabTimeline.mark(.firstFramePresented) }
            return
        }
        incoming = tab
        let deadline = ContinuousClock.now + deadline
        waiting = Task { [weak self] in
            var ready = isReady()
            while !ready, !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: Self.checkInterval)
                ready = isReady()
            }
            guard !Task.isCancelled, let self, self.incoming == tab else { return }
            self.incoming = nil
            self.shown = tab
            self.waiting = nil
            TabTimeline.mark(ready ? .firstFramePresented : .deadlinePassed)
        }
    }

    /// The tabs to lay out, bottom first: the incoming one under the one still shown.
    var layers: [TabId] {
        [incoming, shown].compactMap(\.self)
    }
}

extension Workspace {
    /// Every pane `tab` shows has presented a frame of its screen, or failed to start.
    func hasPresentedScreens(of tabId: TabId, focusedPaneOnly: Bool) -> Bool {
        guard let tab = session.tabs.first(where: { $0.id == tabId }) else { return true }
        let shown: [PaneId]
        if focusedPaneOnly {
            shown = [tab.focused]
        } else if let zoomed = tab.zoomed {
            shown = [zoomed]
        } else {
            shown = (session.tiledRoot(of: tab) ?? tab.root).panes
        }
        return shown.allSatisfy { failures[$0] != nil || pane($0)?.hasPresentedScreen == true }
    }
}
