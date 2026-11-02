import DesignSystem
import os
import SwiftUI
import TerminalCore
import TerminalRenderer

/// The find bar on the focused pane (⌘F): Ghostty's search, over the pane's own terminal.
///
/// Every match in view is highlighted by the renderer and the selected one is emphasized;
/// Return / ⌘G go to the next (older) match and ⇧Return / ⇧⌘G to the previous one, scrolling
/// the pane to it. Local and plain-SSH panes hold their whole scrollback, so their terminal's
/// search (libghostty-vt's) is the answer. A daemon pane holds only the recent part: the count
/// comes from the daemon's search over the whole scrollback, and going past the oldest match
/// the pane holds pages older scrollback in from the daemon until the next match is there.
struct PaneSearchBar: View {
    let model: WindowModel
    let pane: Pane?

    var body: some View {
        let display = model.searchDisplay
        TerminalSearchBar(
            needle: Bindable(model).searchNeedle,
            caseSensitive: Bindable(model).searchCaseSensitive,
            selected: display.selected, total: display.total,
            onNext: { model.findNext() }, onPrevious: { model.findPrevious() },
            onClose: { model.closeSearch() })
            .onAppear { model.attachSearch(pane) }
            .onDisappear { model.detachSearch(pane) }
            .onChange(of: pane.map(ObjectIdentifier.init)) { model.attachSearch(pane) }
    }
}

extension WindowModel {
    /// The bar's "k/N": the pane's selected match, and the larger of its own count and the
    /// daemon's (which also counts scrollback the pane has not paged in).
    var searchDisplay: (selected: Int?, total: Int?) {
        guard !searchNeedle.isEmpty else { return (nil, nil) }
        if LaunchOptions.mock { return (2, searchTotal) }
        let local = searchStatus
        let total: Int? = switch (local.isComplete, searchTotal) {
        case (_, let remote?): max(remote, local.total)
        case (true, nil): local.total
        case (false, nil): local.total > 0 ? local.total : nil
        }
        return (local.selected, total)
    }

    /// Starts searching `pane` (the focused one, when the bar shows on it).
    func attachSearch(_ pane: Pane?) {
        guard let pane else { return }
        if searchPane !== pane {
            if let old = searchPane { detachSearch(old) }
            searchPane = pane
            pane.view.surface.onSearchStatus = { [weak self, weak pane] status in
                guard let self, let pane, self.searchPane === pane else { return }
                PaneSearchLog.log.debug("status total=\(status.total) sel=\(status.selected ?? -1) complete=\(status.isComplete)")
                self.searchStatus = status
            }
        }
        applySearch()
    }

    /// Ends the search on `pane`: its highlights go.
    func detachSearch(_ pane: Pane?) {
        guard let pane else { return }
        pane.view.surface.onSearchStatus = nil
        pane.view.surface.setSearch("")
        guard searchPane === pane else { return }
        searchPane = nil
        searchStatus = .idle
        searchHistoryTask?.cancel()
    }

    /// The needle and case on the searched pane (nothing while the bar is closed).
    func applySearch() {
        guard let surface = searchPane?.view.surface else { return }
        searchHistoryTask?.cancel()
        surface.setSearch(isSearchShown ? searchNeedle : "", caseSensitive: searchCaseSensitive)
        searchStatus = surface.search?.status ?? .idle
    }

    /// ⌘G / Return: the next match up from the prompt, wrapping at the oldest.
    func findNext() { stepSearch(.next) }

    /// ⇧⌘G / ⇧Return: the next match down, wrapping at the newest.
    func findPrevious() { stepSearch(.previous) }

    /// Esc or ✕: the bar closes, the highlights go and the terminal has the keyboard again.
    func closeSearch() {
        let pane = searchPane ?? workspace?.focusedPane.flatMap { workspace?.pane($0) }
        isSearchShown = false
        detachSearch(pane)
        guard let view = pane?.view else { return }
        #if os(macOS)
        view.window?.makeFirstResponder(view)
        #else
        view.becomeFirstResponder()
        #endif
    }

    private func stepSearch(_ direction: TerminalSearch.Direction) {
        if !isSearchShown {
            // ⌘G with the bar closed brings it back with the last needle.
            isSearchShown = true
        }
        if searchPane == nil { attachSearch(workspace?.focusedPane.flatMap { workspace?.pane($0) }) }
        guard let pane = searchPane, !searchNeedle.isEmpty else { return }
        let surface = pane.view.surface
        searchHistoryTask?.cancel()
        let status = surface.search?.status ?? .idle
        // Past the oldest match this pane holds, while the host has older ones: page them in.
        let atOldest = status.selected.map { $0 == status.total - 1 } ?? (status.total == 0)
        PaneSearchLog.log.debug("step \(String(describing: direction), privacy: .public) local=\(status.total) sel=\(status.selected ?? -1) complete=\(status.isComplete) remote=\(self.searchTotal ?? -1)")
        if direction == .next, atOldest, let remote = searchTotal, remote > status.total {
            pageOlderScrollback(pane, matchesBefore: status.total)
            return
        }
        let found = surface.selectMatch(direction)
        searchStatus = surface.search?.status ?? .idle
        PaneSearchLog.log.debug("selected found=\(found) sel=\(self.searchStatus.selected ?? -1) total=\(self.searchStatus.total)")
    }

    /// Asks the pane's host for older scrollback, page after page, until a match older than
    /// the `matchesBefore` the pane had shows up; then selects it. Wraps to the newest match
    /// when the host has nothing more.
    private func pageOlderScrollback(_ pane: Pane, matchesBefore: Int) {
        searchHistoryTask = Task { @MainActor [weak self, weak pane] in
            var lastProgress = ContinuousClock.now
            while !Task.isCancelled, let pane, ContinuousClock.now - lastProgress < .seconds(3) {
                if pane.backend.requestHistory() { lastProgress = .now }
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let surface = pane.view.surface
                if let total = surface.search?.status.total, total > matchesBefore {
                    surface.selectMatch(.next)
                    self?.searchStatus = surface.search?.status ?? .idle
                    return
                }
            }
            guard !Task.isCancelled, let surface = pane?.view.surface else { return }
            surface.selectMatch(.next)
            self?.searchStatus = surface.search?.status ?? .idle
        }
    }
}

enum PaneSearchLog {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "search")
}
