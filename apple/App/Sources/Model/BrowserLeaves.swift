import DesignSystem
import Foundation
import HostKit
import PaneLayout
import SwiftUI

// Browser pages as panes of a window's split tree, as VS Code editors are (§20): a leaf of a
// window-owned tab (`CompositeTab.browsers`), a tab of its own or beside a terminal. Each has
// its own `WebPage`, kept across tab switches; a page on a host reaches that host's
// `localhost` (its data store and loopback ports, `DevServerRouting`). Where a page is saved
// with the window and comes back after a relaunch.

extension ProgramIdentity {
    static let browser = ProgramIdentity(id: "browser", displayName: "Browser", kind: .remote)
}

extension WindowModel {
    /// The page whose leaf has the focus, if any.
    var focusedBrowser: BrowserPane? {
        guard destination == .terminal, let member = activeMixed?.focusedBrowser else { return nil }
        return browsers.existing(member.id)
    }

    /// Opens a page in a browser leaf: a tab of its own, or beside the focused pane.
    @discardableResult
    func openBrowser(_ url: URL, hostId: String?, placement: EditorPlacement) -> BrowserMember {
        let member = BrowserMember(hostId: hostId, url: url.absoluteString)
        destination = .terminal
        if sheet == .browser { sheet = nil }
        AppModel.log.info("browser opens in \(placement == .tab ? "a tab" : "a split", privacy: .public)")
        if placement == .split {
            if let mixed = activeMixed {
                composites.addBrowser(member, to: mixed.id)
                syncMixedFocus()
                return member
            }
            if let open = workspace, let tab = open.session.activeTab {
                let own = currentGroupId
                let id = composites.addBrowser(member, besideHost: own, tab: tab)
                if pairedTab == TabRef(hostId: own, tab: tab.id) { pairedTab = nil }
                activeMixedTab = id
                syncMixedFocus()
                return member
            }
        }
        noteLeavingTab()
        focus(Self.mixedRef(composites.openBrowser(member)))
        return member
    }

    /// A page beside a host's pane (a program there opened it, or its agent browses): in the
    /// pane's tab, which comes forward. The pane's page when it already has one beside it.
    @discardableResult
    func openBrowser(_ url: URL, beside pane: HostPane) -> BrowserMember {
        let member = BrowserMember(hostId: pane.hostId, url: url.absoluteString)
        destination = .terminal
        if sheet == .browser { sheet = nil }
        if let tab = composites.tab(containing: pane), let leaf = tab.leaf(for: pane) {
            composites.apply(.focus(leaf), to: tab.id)
            composites.addBrowser(member, to: tab.id)
            focusMixedTab(tab.id)
        } else if let open = workspace(ofGroup: pane.hostId), var tab = open.session.tab(containing: pane.pane) {
            tab.focused = pane.pane
            noteLeavingTab()
            let id = composites.addBrowser(member, besideHost: pane.hostId, tab: tab)
            if pairedTab == TabRef(hostId: pane.hostId, tab: tab.id) { pairedTab = nil }
            activeMixedTab = id
            syncMixedFocus()
        } else {
            noteLeavingTab()
            focus(Self.mixedRef(composites.openBrowser(member)))
        }
        return member
    }

    /// A page a page opened (`window.open`, `target=_blank`): a new leaf beside its opener.
    @discardableResult
    func openPopup(_ url: URL, from opener: UUID) -> BrowserMember? {
        guard let tab = composites.tab(containingBrowser: opener), let from = tab.browsers.values.first(where: { $0.id == opener })
        else { return nil }
        let member = BrowserMember(hostId: from.hostId, url: url.absoluteString)
        browsers.popups.insert(member.id)
        composites.addBrowser(member, to: tab.id)
        if activeMixedTab == tab.id { syncMixedFocus() }
        return member
    }

    /// The page shown beside a host's pane, if any (its tab's first).
    func browser(beside pane: HostPane) -> BrowserMember? {
        guard let tab = composites.tab(containing: pane) else { return nil }
        return tab.leaves.lazy.compactMap { tab.browsers[$0] }.first
    }

    /// Closes a browser leaf.
    func closeBrowser(_ id: UUID) {
        guard let tab = composites.tab(containingBrowser: id), let leaf = tab.leaf(forBrowser: id) else { return }
        composites.close(leaf: leaf, in: tab.id)
        if activeMixedTab == tab.id { syncMixedFocus() }
    }

    /// The page moved on: its leaf keeps where it is, for a relaunch.
    func browserNavigated(_ id: UUID, to url: URL) {
        guard let tab = composites.tab(containingBrowser: id), let leaf = tab.leaf(forBrowser: id),
              var member = tab.browsers[leaf], member.url != url.absoluteString, url.scheme != "about"
        else { return }
        member.url = url.absoluteString
        composites.update(browser: member)
    }

    /// A browser leaf's name: its page's title, else its address's host.
    func title(ofBrowser member: BrowserMember) -> String {
        if let title = browsers.existing(member.id)?.page.title, !title.isEmpty { return title }
        return URL(string: member.url)?.host() ?? "Browser"
    }

    /// The icon of a window tab's page (its focused one, or a browser tab's first).
    func favicon(ofMixedTab tab: CompositeTab) -> Image? {
        guard let browser = tab.focusedBrowser ?? (tab.isBrowserOnly ? tab.leaves.lazy.compactMap({ tab.browsers[$0] }).first : nil)
        else { return nil }
        return browsers.existing(browser.id)?.favicon
    }

    /// Palette commands for browser leaves.
    var browserPaletteExtras: [(String, String, String, [String]?, () -> Void)] {
        let start = URL(string: "about:blank")!
        return [
            ("browser-tab", "New Browser Tab", "globe", nil, { [weak self] in
                self?.openBrowser(start, hostId: self?.workspace?.hostId, placement: .tab)
            }),
            ("browser-split", "Open Browser Beside", "rectangle.split.2x1", nil, { [weak self] in
                self?.openBrowser(start, hostId: self?.workspace?.hostId, placement: .split)
            }),
        ]
    }
}

/// A page's icon in a tab row, on the row's mark slot.
struct Favicon: View {
    let image: Image
    let size: CGFloat

    var body: some View {
        image
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: 3))
            .accessibilityHidden(true)
    }
}
