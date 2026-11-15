import DesignSystem
import Foundation
import HostKit
import PaneLayout
import SwiftUI

/// Whether opening something beside a pane brings its tab forward: the user's own actions do;
/// agents' and hosts' requests never take the user's tab, sheet or focus.
enum Reveal: Equatable {
    case bringForward
    case inBackground
}

extension ProgramIdentity {
    static let browser = ProgramIdentity(id: "browser", displayName: "Browser", kind: .remote)
}

extension WindowModel {
    var focusedBrowser: BrowserPane? {
        guard destination == .terminal, let member = activeMixed?.focusedBrowser else { return nil }
        return browsers.existing(member.id)
    }

    /// `origin`: the tab it was opened from (the one on screen when nil); a page in a tab of its
    /// own joins that tab's project, right after it.
    @discardableResult
    func openBrowser(_ url: URL, hostId: String?, placement: EditorPlacement, origin: TabRef? = nil) -> BrowserMember {
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
            if let workspace, let tab = workspace.session.activeTab {
                let groupId = currentGroupId
                if let id = replaceHostTab(TabRef(hostId: groupId, tab: tab.id), with: { composites.addBrowser(member, besideHost: groupId, tab: tab) }) {
                    activeMixedTab = id
                }
                syncMixedFocus()
                return member
            }
        }
        let origin = origin ?? currentTab
        noteLeavingTab()
        let ref = Self.mixedRef(composites.openBrowser(member))
        join(ref, projectOf: origin)
        focus(ref)
        return member
    }

    /// Opens a page beside a pane, in the pane's tab. `.inBackground` (an agent's or a host's
    /// request): the user's tab, sheet and focus stay as they are, and the tab's row marks the
    /// change; `.bringForward` (the user's own action): the tab comes forward with the page focused.
    @discardableResult
    func openBrowser(_ url: URL, beside pane: HostPane, axis: Axis = .horizontal, reveal: Reveal = .inBackground) -> BrowserMember {
        let member = BrowserMember(hostId: pane.hostId == HostGroups.localId ? nil : pane.hostId, url: url.absoluteString)
        let leafFocus: NewLeafFocus = reveal == .bringForward ? .newLeaf : .unchanged
        if reveal == .bringForward {
            destination = .terminal
            if sheet == .browser { sheet = nil }
        }
        if let tab = composites.tab(containing: pane), let leaf = tab.leaf(for: pane) {
            composites.addBrowser(member, to: tab.id, beside: leaf, axis: axis, focus: leafFocus)
            if reveal == .bringForward {
                focusMixedTab(tab.id)
            } else {
                noteChangedOutOfSight(Self.mixedRef(tab.id))
            }
        } else if let hostWorkspace = workspace(ofGroup: pane.hostId), let tab = hostWorkspace.session.tab(containing: pane.pane) {
            let hostRef = TabRef(hostId: pane.hostId, tab: tab.id)
            let wasOnScreen = currentTab == hostRef
            if reveal == .bringForward { noteLeavingTab() }
            guard let id = replaceHostTab(hostRef, with: {
                composites.addBrowser(member, besideHost: pane.hostId, tab: tab, pane: pane.pane, axis: axis, focus: leafFocus)
            }) else { return member }
            if reveal == .bringForward || wasOnScreen {
                activeMixedTab = id
                syncMixedFocus()
            } else {
                noteChangedOutOfSight(Self.mixedRef(id))
            }
        } else {
            let origin = tabRef(containing: pane)
            if reveal == .bringForward { noteLeavingTab() }
            let ref = Self.mixedRef(composites.openBrowser(member))
            join(ref, projectOf: origin)
            if reveal == .bringForward { focus(ref) } else { noteChangedOutOfSight(ref) }
        }
        return member
    }

    /// The tab showing a host's pane: a mixed tab holding it, else its host tab.
    func tabRef(containing pane: HostPane) -> TabRef? {
        if let mixed = composites.tab(containing: pane) { return Self.mixedRef(mixed.id) }
        guard let tab = groups.group(pane.hostId)?.tabs.first(where: { $0.root.contains(pane.pane) }) else { return nil }
        return TabRef(hostId: pane.hostId, tab: tab.id)
    }

    /// ⇧⌘B: a browser tab on the dev server the focused pane runs, else the start page.
    func openBrowserTab() {
        guard destination == .terminal else { return }
        if let mixed = activeMixed {
            if let member = mixed.focusedMember {
                openBrowserTab(fromPane: member.pane, onGroup: member.hostId)
            } else {
                openStartPage(hostId: mixed.focusedBrowser?.hostId)
            }
        } else if let workspace, let pane = workspace.focusedPane {
            openBrowserTab(fromPane: pane, onGroup: workspace.groupId)
        } else {
            openStartPage(hostId: workspace?.hostId)
        }
    }

    /// A browser tab on the dev server the pane runs, else the start page.
    func openBrowserTab(fromPane pane: PaneId, onGroup groupId: String) {
        let server = devServer(ofPane: pane, onGroup: groupId)
        guard opensToolsAsLeaves else { return showBrowserSheet(on: server) }
        let hostId = groupId == HostGroups.localId ? nil : groupId
        let origin = tabRef(containing: HostPane(hostId: groupId, pane: pane))
        openBrowser(server.map(DevServerRouting.pageURL) ?? URL(string: "about:blank")!, hostId: hostId, placement: .tab, origin: origin)
    }

    /// A page beside the pane: the dev server the pane runs, else the start page.
    func openBrowser(besidePane pane: PaneId, onGroup groupId: String, axis: Axis = .horizontal) {
        let server = devServer(ofPane: pane, onGroup: groupId)
        guard opensToolsAsLeaves else { return showBrowserSheet(on: server) }
        openBrowser(server.map(DevServerRouting.pageURL) ?? URL(string: "about:blank")!, beside: HostPane(hostId: groupId, pane: pane), axis: axis, reveal: .bringForward)
    }

    private func openStartPage(hostId: String?) {
        guard opensToolsAsLeaves else { return showBrowserSheet(on: nil) }
        openBrowser(URL(string: "about:blank")!, hostId: hostId, placement: .tab)
    }

    /// Where tools are not leaves (iPhone, a narrow iPad window): the browser sheet.
    private func showBrowserSheet(on server: DetectedPort?) {
        if let server {
            Task { await openPort(server) }
        } else {
            browserURL = nil
            sheet = .browser
        }
    }

    func openBrowserBesideFocusedPane(axis: Axis = .horizontal) {
        guard destination == .terminal else { return }
        if let mixed = activeMixed {
            if let member = mixed.focusedMember {
                openBrowser(besidePane: member.pane, onGroup: member.hostId, axis: axis)
            } else {
                openBrowser(URL(string: "about:blank")!, hostId: mixed.focusedBrowser?.hostId, placement: .split)
            }
        } else if let workspace, let pane = workspace.focusedPane {
            openBrowser(besidePane: pane, onGroup: workspace.groupId, axis: axis)
        }
    }

    private func devServer(ofPane pane: PaneId, onGroup groupId: String) -> DetectedPort? {
        guard let context = HostContext.host(groupId, app: app) else { return nil }
        let owned = context.hub.ports.filter { $0.paneId.map { PaneId($0) } == pane }
        return LivePortSource.ports(owned, meta: context.daemon.meta.all).first(where: \.isHTTP)
    }

    /// A page opened by `window.open` or `target=_blank`, as a new leaf beside its opener.
    /// `id` is the popup pane's, already made by `BrowserPanes.onPopupPane`.
    @discardableResult
    func openPopup(_ url: URL, from opener: UUID, id: UUID = UUID()) -> BrowserMember? {
        guard let tab = composites.tab(containingBrowser: opener), let openerMember = tab.browsers.values.first(where: { $0.id == opener })
        else { return nil }
        let member = BrowserMember(id: id, hostId: openerMember.hostId, url: url.absoluteString)
        browsers.popups.insert(member.id)
        // An agent's click opens it without taking the tab's focus.
        let byAgent = browsers.existing(opener)?.agentActing == true
        composites.addBrowser(member, to: tab.id, beside: tab.leaf(forBrowser: opener), focus: byAgent ? .unchanged : .newLeaf)
        if byAgent {
            noteChangedOutOfSight(Self.mixedRef(tab.id))
        } else if activeMixedTab == tab.id {
            syncMixedFocus()
        }
        return member
    }

    func browser(beside pane: HostPane) -> BrowserMember? {
        guard let tab = composites.tab(containing: pane) else { return nil }
        return tab.leaves.lazy.compactMap { tab.browsers[$0] }.first
    }

    func closeBrowser(_ id: UUID) {
        guard let tab = composites.tab(containingBrowser: id), let leaf = tab.leaf(forBrowser: id) else { return }
        composites.close(leaf: leaf, in: tab.id)
        if activeMixedTab == tab.id { syncMixedFocus() }
    }

    /// Saves the page's address for a relaunch.
    func browserNavigated(_ id: UUID, to url: URL) {
        guard let tab = composites.tab(containingBrowser: id), let leaf = tab.leaf(forBrowser: id),
              var member = tab.browsers[leaf], member.url != url.absoluteString, url.scheme != "about"
        else { return }
        member.url = url.absoluteString
        composites.update(browser: member)
    }

    func title(ofBrowser member: BrowserMember) -> String {
        if let title = browsers.existing(member.id)?.page.title, !title.isEmpty { return title }
        return URL(string: member.url)?.host() ?? "Browser"
    }

    func favicon(ofMixedTab tab: CompositeTab) -> Image? {
        guard let browser = tab.focusedBrowser ?? (tab.isBrowserOnly ? tab.leaves.lazy.compactMap({ tab.browsers[$0] }).first : nil)
        else { return nil }
        return browsers.existing(browser.id)?.favicon
    }

    var browserPaletteExtras: [(String, String, String, [String]?, () -> Void)] {
        [
            ("browser-tab", WorkspaceAction.newBrowserTab.title, "globe", WorkspaceAction.newBrowserTab.shortcut.symbols, { [weak self] in
                self?.openBrowserTab()
            }),
            ("browser-split", WorkspaceAction.openBrowserBeside.title, "rectangle.split.2x1", WorkspaceAction.openBrowserBeside.shortcut.symbols, { [weak self] in
                self?.openBrowserBesideFocusedPane()
            }),
            ("browser-below", "Open Browser Below", "rectangle.split.1x2", nil, { [weak self] in
                self?.openBrowserBesideFocusedPane(axis: .vertical)
            }),
        ]
    }
}

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
