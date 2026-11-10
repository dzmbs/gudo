import DesignSystem
import Foundation
import HostKit
import PaneLayout
import SwiftUI

extension ProgramIdentity {
    static let browser = ProgramIdentity(id: "browser", displayName: "Browser", kind: .remote)
}

extension WindowModel {
    var focusedBrowser: BrowserPane? {
        guard destination == .terminal, let member = activeMixed?.focusedBrowser else { return nil }
        return browsers.existing(member.id)
    }

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
            if let workspace, let tab = workspace.session.activeTab {
                let groupId = currentGroupId
                let id = composites.addBrowser(member, besideHost: groupId, tab: tab)
                if pairedTab == TabRef(hostId: groupId, tab: tab.id) { pairedTab = nil }
                activeMixedTab = id
                syncMixedFocus()
                return member
            }
        }
        let origin = currentTab
        noteLeavingTab()
        let ref = Self.mixedRef(composites.openBrowser(member))
        join(ref, projectOf: origin)
        focus(ref)
        return member
    }

    /// Opens a page in the pane's tab, which comes forward.
    @discardableResult
    func openBrowser(_ url: URL, beside pane: HostPane) -> BrowserMember {
        let member = BrowserMember(hostId: pane.hostId == HostGroups.localId ? nil : pane.hostId, url: url.absoluteString)
        destination = .terminal
        if sheet == .browser { sheet = nil }
        if let tab = composites.tab(containing: pane), let leaf = tab.leaf(for: pane) {
            composites.apply(.focus(leaf), to: tab.id)
            composites.addBrowser(member, to: tab.id)
            focusMixedTab(tab.id)
        } else if let hostWorkspace = workspace(ofGroup: pane.hostId), var tab = hostWorkspace.session.tab(containing: pane.pane) {
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
        openBrowser(server.map(DevServerRouting.pageURL) ?? URL(string: "about:blank")!, hostId: hostId, placement: .tab)
    }

    /// A page beside the pane: the dev server the pane runs, else the start page.
    func openBrowser(besidePane pane: PaneId, onGroup groupId: String) {
        let server = devServer(ofPane: pane, onGroup: groupId)
        guard opensToolsAsLeaves else { return showBrowserSheet(on: server) }
        openBrowser(server.map(DevServerRouting.pageURL) ?? URL(string: "about:blank")!, beside: HostPane(hostId: groupId, pane: pane))
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

    func openBrowserBesideFocusedPane() {
        guard destination == .terminal else { return }
        if let mixed = activeMixed {
            if let member = mixed.focusedMember {
                openBrowser(besidePane: member.pane, onGroup: member.hostId)
            } else {
                openBrowser(URL(string: "about:blank")!, hostId: mixed.focusedBrowser?.hostId, placement: .split)
            }
        } else if let workspace, let pane = workspace.focusedPane {
            openBrowser(besidePane: pane, onGroup: workspace.groupId)
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
        composites.addBrowser(member, to: tab.id)
        if activeMixedTab == tab.id { syncMixedFocus() }
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
