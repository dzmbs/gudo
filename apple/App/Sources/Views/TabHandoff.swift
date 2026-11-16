import Foundation
import Observation
import PaneLayout

/// The shown tab stays on top of a newly selected one until that has drawn its screen; the newest selection wins.
@Observable
final class TabHandoff {
    private(set) var shown: TabId?
    private(set) var incoming: TabId?
    /// A tab just made that is not on screen yet: its row and chip wait for it, so they never
    /// lead its content or read a name it has not got yet.
    private(set) var arriving: TabId?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var arrival: Task<Void, Never>?
    @ObservationIgnored private let deadline: Duration

    /// About one display frame: readiness is a frame having been presented.
    static let checkInterval = Duration.milliseconds(4)

    init(deadline: Duration = .milliseconds(300)) {
        self.deadline = deadline
    }

    /// `tab` was just made and selected; held back no longer than a selection waits.
    func arrive(_ tab: TabId) {
        guard tab != shown else { return }
        arriving = tab
        arrival?.cancel()
        arrival = Task { [weak self, deadline] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled, let self, self.arriving == tab else { return }
            self.arriving = nil
        }
    }

    /// The tab selected now; `isReady` says whether its panes have presented their screens.
    func select(_ tab: TabId?, isReady: @escaping @MainActor () -> Bool) {
        defer { if arriving != nil, arriving != incoming { arriving = nil } }
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
            if self.arriving == tab { self.arriving = nil }
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
    /// The tab on screen: the selected one once it has drawn, so the window's title changes
    /// with its content.
    var shownTab: Tab? {
        tabHandoff.shown.flatMap { shown in session.tabs.first { $0.id == shown } } ?? session.activeTab
    }

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
