import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import WebKit

/// In-app browser for localhost previews and links printed in a pane. Safari 26's layout: a
/// floating glass address capsule at the bottom on iPhone; a compact top bar with Chrome's
/// omnibox on iPad and Mac. The page itself stays edge to edge; glass is only on the controls.
struct BrowserView: View {
    /// The host a dev server page comes from (its data store routes to it, S-BR1): named next
    /// to the address.
    var routedHost: (id: String, name: String)?
    var onOpenExternally: (URL) -> Void = { _ in }
    /// Shows a leading "Done" / back control (the browser sheet, the ports list).
    var onDone: (() -> Void)?
    var doneTitle = "Done"
    /// A browser leaf: its shortcuts only while it has the focus, a close button, and where it
    /// navigated reported.
    var isFocused = true
    var onClose: (() -> Void)?
    var onNavigate: ((URL) -> Void)?
    /// A new browser tab beside this one (the bar's +).
    var onNewTab: (() -> Void)?
    /// The sheet's page moves into a browser tab.
    var onOpenAsTab: ((URL) -> Void)?
    /// The user points at an element for the agent beside the page.
    var onPointOut: (() -> Void)?
    /// Opens the page's recorded agent sessions (Session Replay).
    var onReplays: (() -> Void)?

    @State private var pane: BrowserPane
    /// This view's hold on the page's one `WebView`.
    @State private var hold: BrowserPane.ViewHold
    private var page: any BrowserPageContent { pane.page }
    private var initialURL: URL { pane.initialURL }
    #if DEBUG
    /// UI tests: connections sent to `routedHost` (proof the page went through the host).
    @State private var routedCount = 0
    #endif

    /// `dataStore`: a host's own store for its dev servers (`DevServerRouting`), else the default.
    /// `intercept` sees each navigation first; true stops it (a sign-in code taken from it).
    init(
        initialURL: URL, dataStore: WKWebsiteDataStore? = nil, routedHost: (id: String, name: String)? = nil,
        intercept: ((URL) -> Bool)? = nil,
        onOpenExternally: @escaping (URL) -> Void = { _ in }, onDone: (() -> Void)? = nil, doneTitle: String = "Done"
    ) {
        let pane = BrowserPane(url: initialURL, hostId: routedHost?.id, dataStore: dataStore)
        pane.intercept = intercept
        self.init(pane: pane, routedHost: routedHost, onOpenExternally: onOpenExternally, onDone: onDone, doneTitle: doneTitle)
    }

    /// A page that outlives the view (a browser leaf's).
    init(
        pane: BrowserPane, routedHost: (id: String, name: String)? = nil,
        onOpenExternally: @escaping (URL) -> Void = { _ in }, onDone: (() -> Void)? = nil, doneTitle: String = "Done",
        isFocused: Bool = true, onClose: (() -> Void)? = nil, onNavigate: ((URL) -> Void)? = nil,
        onNewTab: (() -> Void)? = nil, onPointOut: (() -> Void)? = nil, onReplays: (() -> Void)? = nil
    ) {
        self.isFocused = isFocused
        self.onPointOut = onPointOut
        self.onReplays = onReplays
        self.onClose = onClose
        self.onNavigate = onNavigate
        self.onNewTab = onNewTab
        self.routedHost = routedHost
        self.onOpenExternally = onOpenExternally
        self.onDone = onDone
        self.doneTitle = doneTitle
        _pane = State(initialValue: pane)
        _hold = State(initialValue: BrowserPane.ViewHold(pane))
    }
    @Environment(WindowModel.self) private var model: WindowModel?
    @Environment(\.colorScheme) private var chromeScheme
    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    @AppStorage(WebsiteAppearance.key) private var followsTheme = true
    /// What the field holds: the page's address (Chrome's short form) until it is edited.
    @State private var address = ""
    @State private var addressSelection: TextSelection?
    /// The suggestion arrow keys picked under the address field (-1: none).
    @State private var selection = -1
    /// A page asked for from the start page, which stays until it is gone or failed.
    @State private var leavingStart = false
    @State private var isFieldHovered = false
    @FocusState private var isEditing: Bool
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        // One WebView whatever the size class: a page may be shown by one WebView only, and a
        // size class that flips while the sheet comes up (presented right after a popover)
        // would otherwise make a second one before the first is gone (a WebKit trap).
        // The regular bar sits above the page, not over it: the page then has no top inset, so
        // its pictures (`BrowserAgent`) start at the document's top.
        VStack(spacing: 0) {
            if !isCompact {
                regularBar
                    .overlay(alignment: .bottom) { progressLine }
            }
            ZStack {
                Group {
                    if let web = pane.webPage {
                        if pane.mayShow(in: hold.id) {
                            WebView(web)
                                .webViewBackForwardNavigationGestures(.enabled)
                                // `prefers-color-scheme` on the page: the theme's, or the device's.
                                .environment(\.colorScheme, followsTheme ? chromeScheme : WebsiteAppearance.systemScheme)
                        }
                    } else if let popup = pane.popupPage {
                        PopupWebView(page: popup, colorScheme: followsTheme ? chromeScheme : WebsiteAppearance.systemScheme)
                    }
                }
                .ignoresSafeArea(edges: isCompact ? .bottom : [])
                if showsStart { startPage }
            }
            .overlay(alignment: isCompact ? .bottom : .top) {
                if isEditing, !suggestions.isEmpty {
                    AddressSuggestionList(suggestions: suggestions, selection: selection) { pick($0.url) }
                        .padding(DS.Space.xs)
                        .frame(maxWidth: 640)
                        .floatingPanel()
                        .padding(DS.Space.s)
                        .transition(.opacity.combined(with: .scale(0.98, anchor: isCompact ? .bottom : .top)))
                }
            }
            .animation(DS.Motion.menu, value: isEditing && !suggestions.isEmpty)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isCompact { compactBar }
            }
        }
        .overlay(alignment: .top) {
            if isCompact { progressLine }
        }
        .background { shortcuts }
        .onAppear {
            pane.start()
            showCurrentAddress()
        }
        .onChange(of: page.url) { _, url in
            if !isEditing { showCurrentAddress() }
            guard let url else { return }
            if !isBlank { leavingStart = false }
            onNavigate?(url)
            BrowserHistory.shared.record(url, title: page.title)
        }
        .onChange(of: page.title) { _, title in
            if let url = page.url { BrowserHistory.shared.retitle(url, title) }
        }
        .onChange(of: page.isLoading) { _, loading in
            if !loading, isBlank { leavingStart = false }
            if !loading { Task { await pane.refreshFavicon() } }
        }
        .onChange(of: isEditing) { _, editing in
            if editing { beginEditing() } else { showCurrentAddress() }
        }
        .onChange(of: address) { selection = -1 }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if let routedHost {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier("browser-routed")
                    .accessibilityValue("\(routedCount)")
                    .task {
                        while !Task.isCancelled {
                            routedCount = DevServerRouting.shared.routedConnections(forHost: routedHost.id)
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
            }
        }
        #endif
    }

    /// Offers moving the page into a browser tab.
    func onOpenAsTab(_ action: @escaping (URL) -> Void) -> BrowserView {
        var view = self
        view.onOpenAsTab = action
        return view
    }

    // MARK: Start page

    private var isBlank: Bool { (page.url ?? initialURL).absoluteString == "about:blank" }
    private var showsStart: Bool { isBlank && !leavingStart }

    private var startPage: some View {
        let servers = model?.devServers(onHost: pane.hostId)
        return BrowserStartPage(
            hostName: servers?.hostName ?? "", devServers: servers?.ports ?? [],
            // The bar's field has the keyboard when it was reached for (⌘L) first.
            focusOnAppear: isFocused && !isEditing,
            open: pick, openDevServer: openDevServer)
    }

    private var suggestions: [AddressSuggestion] {
        guard address != (page.url?.absoluteString ?? ""), address != shortAddress else { return [] }
        return AddressSuggestion.make(
            for: address, history: BrowserHistory.shared.entries,
            devServers: model?.devServers(onHost: pane.hostId).ports ?? [], engine: engine, locale: .current)
    }

    private func pick(_ url: URL) {
        isEditing = false
        if isBlank { leavingStart = true }
        pane.load(url)
        address = BrowserAddress.display(url)
    }

    /// On a page that reaches its host's `localhost` (a browser leaf), here; else through a
    /// forward, as from the ports list.
    private func openDevServer(_ port: DetectedPort) {
        if pane.prepare != nil || pane.hostId == nil {
            pick(DevServerRouting.pageURL(for: port))
        } else if let model {
            Task { await model.openPort(port) }
        }
    }

    // MARK: Bars

    /// iPad and Mac: Chrome's bar. History and reload, the omnibox, then the page's actions.
    private var regularBar: some View {
        HStack(spacing: DS.Space.xs) {
            if let onDone {
                // Safari's way back to where the page came from: the ink, never the accent
                // (toolbars are monochrome).
                Button(action: onDone) {
                    if doneTitle == "Done" {
                        Text(doneTitle)
                    } else {
                        Label(doneTitle, systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .padding(.trailing, DS.Space.xs)
                .accessibilityIdentifier("browser-done")
            }
            navigationButtons
            reloadButton
            addressField
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Space.xs)
            if let onPointOut {
                Button("Point Out to Agent", systemImage: "hand.point.up.left", action: onPointOut)
                    .help("Point Out to Agent")
                    .accessibilityIdentifier("browser-point-out")
            }
            if let onReplays {
                Button("Replays", systemImage: "play.rectangle.on.rectangle", action: onReplays)
                    .help("Replays")
                    .accessibilityIdentifier("browser-replays")
            }
            if let onNewTab {
                Button("New Browser Tab", systemImage: "plus", action: onNewTab)
                    .help("New Browser Tab")
                    .accessibilityIdentifier("browser-new-tab")
            }
            moreMenu
            if let onClose {
                Button("Close Page", systemImage: "xmark", action: onClose)
                    .help("Close Page")
                    .accessibilityIdentifier("browser-close")
            }
        }
        .buttonStyle(.quiet)
        .labelStyle(.iconOnly)
        .padding(.horizontal, DS.Space.s)
        .frame(height: DS.Size.tabBar)
        .background(DS.Palette.base)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// Chrome's ⋮: what is done with the page elsewhere.
    private var moreMenu: some View {
        Menu("More", systemImage: "ellipsis") {
            if let url = page.url, !isBlank {
                ShareLink(item: url)
                Button("Copy Address", systemImage: "doc.on.doc") { FilesPasteboard.copy(url.absoluteString) }
            }
            if let onOpenAsTab {
                Button("Open as Tab", systemImage: "plus.square.on.square") { onOpenAsTab(page.url ?? initialURL) }
                    .accessibilityIdentifier("browser-open-tab")
            }
            Button("Open in Safari", systemImage: "safari", action: openExternally)
                .disabled(isBlank)
        }
        .menuIndicator(.hidden)
        .help("More")
        .accessibilityIdentifier("browser-more")
    }

    /// iPhone: one floating glass capsule with the controls around the address.
    private var compactBar: some View {
        GlassEffectContainer(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                if !isEditing {
                    HStack(spacing: 0) {
                        if let onDone {
                            Button(doneTitle, systemImage: "xmark", action: onDone)
                                .accessibilityIdentifier("browser-done")
                        }
                        navigationButtons
                    }
                    .padding(.horizontal, DS.Space.xs)
                    .frame(height: 44)
                    .floatingCapsule(interactive: true)
                }
                addressField
                    .frame(height: 44)
                    .floatingCapsule(interactive: true)
                if !isEditing {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Reload", systemImage: "arrow.clockwise") { page.reloadPage() }
                        if let url = page.url {
                            ShareLink(item: url)
                        }
                        if let onNewTab {
                            Button("New Browser Tab", systemImage: "plus", action: onNewTab)
                        }
                        if let onPointOut {
                            Button("Point Out to Agent", systemImage: "hand.point.up.left", action: onPointOut)
                        }
                        if let onReplays {
                            Button("Replays", systemImage: "play.rectangle.on.rectangle", action: onReplays)
                                .accessibilityIdentifier("browser-replays")
                        }
                        if let onOpenAsTab {
                            Button("Open as Tab", systemImage: "plus.square.on.square") { onOpenAsTab(page.url ?? initialURL) }
                        }
                        Button("Open in Safari", systemImage: "safari", action: openExternally)
                        if let onClose {
                            Button("Close Page", systemImage: "xmark", action: onClose)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .floatingCapsule(interactive: true)
                }
            }
            .buttonStyle(.bar)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.s)
        .animation(DS.Motion.snappy, value: isEditing)
    }

    /// Back and forward; a long press (or a held click) lists the history, as in Safari.
    @ViewBuilder private var navigationButtons: some View {
        let list = page.history
        Menu {
            ForEach(list.back.reversed()) { item in
                Button(Self.title(of: item)) { page.go(to: item) }
            }
        } label: {
            Label("Back", systemImage: "chevron.backward")
        } primaryAction: {
            page.goBack()
        }
        .menuIndicator(.hidden)
        .disabled(list.back.isEmpty)
        .help("Back")
        .accessibilityIdentifier("browser-back")
        Menu {
            ForEach(list.forward) { item in
                Button(Self.title(of: item)) { page.go(to: item) }
            }
        } label: {
            Label("Forward", systemImage: "chevron.forward")
        } primaryAction: {
            page.goForward()
        }
        .menuIndicator(.hidden)
        .disabled(list.forward.isEmpty)
        .help("Forward")
        .accessibilityIdentifier("browser-forward")
    }

    private static func title(of item: BrowserHistoryItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return BrowserAddress.display(item.url)
    }

    private var reloadButton: some View {
        Button(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
            if page.isLoading { page.stopLoading() } else { page.reloadPage() }
        }
        .help(page.isLoading ? "Stop" : "Reload")
        .contentTransition(.symbolEffect(.replace))
        .accessibilityIdentifier("browser-reload")
    }

    /// Chrome's keys while the page's pane has the focus: ⌘L the address, ⌘R reload, ⌘[ ⌘] history,
    /// ⌘. or Esc gives up an edit.
    @ViewBuilder private var shortcuts: some View {
        if isFocused {
            Group {
                Button("Open Location") { isEditing = true }
                    .keyboardShortcut("l")
                Button("Reload") { page.reloadPage() }
                    .keyboardShortcut("r")
                Button("Back") { page.goBack() }
                    .keyboardShortcut("[")
                Button("Forward") { page.goForward() }
                    .keyboardShortcut("]")
                if isEditing {
                    Button("Cancel Edit") { cancelEditing() }
                        .keyboardShortcut(".")
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Address

    /// Chrome's omnibox: always a field. A click or tap takes the keyboard and selects the whole
    /// address; Return goes, Esc gives the page's address back.
    private var addressField: some View {
        HStack(spacing: DS.Space.s) {
            securityMark
            TextField("Search \(engine.title) or enter address", text: $address, selection: $addressSelection)
                .font(.callout)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.webSearch)
                .submitLabel(.go)
                #endif
                .focused($isEditing)
                .onSubmit(go)
                .onKeyPress(.downArrow) { moveSelection(1) }
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onKeyPress(.escape) {
                    cancelEditing()
                    return .handled
                }
                .foregroundStyle(isEditing ? DS.Palette.text : DS.Palette.textSecondary)
                .help(page.title.isEmpty ? (page.url?.absoluteString ?? "") : page.title)
                .accessibilityLabel("Address" + (isBlank ? "" : ", \(displayHost)") + (servingHost.map { ", on \($0)" } ?? ""))
                .accessibilityIdentifier("browser-address")
            if isEditing, !address.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { address = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textTertiary)
            } else if !isEditing, let servingHost {
                Text(servingHost)
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(minHeight: 28)
        .background {
            if !isCompact {
                Capsule().fill(isFieldHovered && !isEditing ? DS.Palette.selectedFill : DS.Palette.hoverFill)
            }
        }
        .overlay {
            if !isCompact, isEditing { Capsule().strokeBorder(DS.Palette.accent, lineWidth: 1.5) }
        }
        .contentShape(.capsule)
        .onHover { isFieldHovered = $0 }
        .onTapGesture { isEditing = true }
        #if os(iOS)
        .hoverEffect(.highlight)
        #endif
        .animation(.easeOut(duration: 0.15), value: isEditing)
    }

    /// Chrome's site mark: a lock on a secure page, a warning on a plain one out on the
    /// network, a server on a dev server; a magnifier while typing.
    private var securityMark: some View {
        let url = page.url ?? initialURL
        let (symbol, help, style): (String, String, ChromeStyle) =
            if isEditing || isBlank { ("magnifyingglass", "Search or enter address", DS.Palette.textTertiary) }
            else if url.scheme == "https" { (page.hasOnlySecureContent ? "lock.fill" : "lock.open.fill", page.hasOnlySecureContent ? "Connection Is Secure" : "Parts of This Page Are Not Secure", DS.Palette.textSecondary) }
            else if let host = url.host(), DevServerNames.isRouted(host) || WindowModel.isLoopback(host) { ("server.rack", "Dev Server", DS.Palette.textSecondary) }
            else { ("exclamationmark.triangle.fill", "Not Secure", DS.Palette.attention) }
        return Image(systemName: symbol)
            .font(.subheadline.weight(.medium))
            .imageScale(.small)
            .foregroundStyle(style)
            .frame(width: 14)
            .contentTransition(.symbolEffect(.replace))
            .help(help)
            .accessibilityLabel(help)
            .accessibilityIdentifier("browser-security")
    }

    /// The page's address as the field shows it when not editing.
    private var shortAddress: String { isBlank ? "" : BrowserAddress.display(page.url ?? initialURL) }

    private func showCurrentAddress() {
        address = shortAddress
        addressSelection = nil
    }

    /// The full address, all of it selected, so typing replaces it.
    private func beginEditing() {
        address = isBlank ? "" : (page.url ?? initialURL).absoluteString
        // After the field has placed its caret where it was tapped.
        Task { @MainActor in
            addressSelection = TextSelection(range: address.startIndex..<address.endIndex)
        }
    }

    private func cancelEditing() {
        isEditing = false
        showCurrentAddress()
    }

    /// `github.com`, or `localhost:5173` for local servers (the port matters there).
    private var displayHost: String {
        let url = page.url ?? initialURL
        guard let host = url.host() else { return url.absoluteString }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.hasSuffix(".localhost")
        if isLocal, let port = url.port { return "\(host):\(port)" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The host serving the page, when it is one of its dev servers (`localhost:3000` there).
    private var servingHost: String? {
        guard let routedHost, !routedHost.name.isEmpty, let host = (page.url ?? initialURL).host(),
              DevServerNames.isRouted(host) else { return nil }
        return routedHost.name
    }

    /// A 2 pt accent line along the bar's bottom edge that fills while loading and fades when done.
    private var progressLine: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(DS.Palette.accent)
                .frame(width: geo.size.width * page.estimatedProgress)
                .animation(DS.Motion.overlay, value: page.estimatedProgress)
        }
        .frame(height: 2)
        .opacity(page.isLoading ? 1 : 0)
        .animation(DS.Motion.overlay, value: page.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func go() {
        let picked = suggestions.indices.contains(selection) ? suggestions[selection].url : nil
        if let url = picked ?? BrowserAddress.url(for: address, engine: engine, locale: .current) {
            pick(url)
        } else {
            cancelEditing()
        }
    }

    private func moveSelection(_ step: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        selection = AddressSuggestion.step(selection, by: step, count: suggestions.count)
        return .handled
    }

    private func openExternally() {
        let url = page.url ?? initialURL
        onOpenExternally(url)
        openURL(url)
    }
}

/// A browser leaf of a split tree: the window's page for it (made once, kept across tab
/// switches), closed and focused through the window.
struct BrowserLeafView: View {
    let member: BrowserMember
    let isFocused: Bool
    let focus: () -> Void
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @State private var pane: BrowserPane?

    var body: some View {
        Group {
            if let pane {
                BrowserView(
                    pane: pane, routedHost: member.hostId.map { (id: $0, name: model.groupName($0)) },
                    isFocused: isFocused, onClose: { model.closeBrowser(member.id) },
                    onNavigate: { model.browserNavigated(member.id, to: $0) },
                    onNewTab: { model.openBrowser(URL(string: "about:blank")!, hostId: member.hostId, placement: .tab) },
                    onPointOut: terminal == nil ? nil : { pointOut(pane) },
                    onReplays: ReplayStore.shared.sessions.contains { $0.page == member.id } ? { model.showReplays(.page(member.id)) } : nil)
                    .simultaneousGesture(TapGesture().onEnded { if !isFocused { focus() } })
                    .overlay(alignment: .bottom) { AgentBar(pane: pane) }
            } else {
                theme.background
            }
        }
        .task(id: member.id) { pane = await model.browsers.pane(for: member, app: model.app) }
        .overlay(alignment: .topLeading) {
            // A marker: an identifier on the container would replace its controls' own.
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Browser page")
                .accessibilityIdentifier("browser-leaf")
        }
        // One page per leaf: never reuse another leaf's view.
        .id(member.id)
    }
}

extension BrowserLeafView {
    /// The terminal in the page's tab (the agent's), if any.
    private var terminal: HostPane? {
        guard let tab = model.composites.tab(containingBrowser: member.id) else { return nil }
        return tab.leaves.lazy.compactMap { tab.members[$0] }.first { $0.hostId != HostGroups.localId }
    }

    /// The next tap on the page picks an element, which goes to the terminal as text for the
    /// agent (pasted, not sent).
    private func pointOut(_ pane: BrowserPane) {
        guard let terminal, let daemon = model.app.hosts.connection(terminal.hostId) as? DaemonConnection else { return }
        model.toasts.show(Toast("Tap what to point out", systemImage: "hand.point.up.left"))
        Task {
            _ = try? await pane.page.run("return window.__un.pick()", in: BrowserAgentScript.world)
            var picked = ""
            for _ in 0..<600 where picked.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
                picked = (try? await pane.page.run("return window.__un.picked()", in: BrowserAgentScript.world) as? String) ?? ""
            }
            guard !picked.isEmpty else { return }
            daemon.paste("In the browser beside you: " + picked.replacingOccurrences(of: "\n", with: " ") + " ", into: terminal.pane.rawValue)
            model.toasts.show(Toast("Pointed out to the terminal", systemImage: "checkmark.circle.fill", style: .success))
        }
    }
}

/// The page's `alert`, `confirm` or `prompt`, answered here or by the agent (`browser_dialog`).
private struct DialogCard: View {
    let dialog: BrowserPane.PageDialog
    @State private var text: String

    init(dialog: BrowserPane.PageDialog) {
        self.dialog = dialog
        _text = State(initialValue: dialog.defaultText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Label("The page asks", systemImage: "exclamationmark.bubble")
                .font(DS.Font.banner)
            Text(dialog.message)
                .font(.callout)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if dialog.kind == .prompt {
                TextField("Answer", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("page-dialog-text")
            }
            HStack {
                Spacer()
                if dialog.kind != .alert {
                    Button(dialog.kind == .beforeunload ? "Stay" : "Cancel") { dialog.answer(false, nil) }
                        .buttonStyle(.quiet)
                        .accessibilityIdentifier("page-dialog-dismiss")
                }
                Button(dialog.kind == .beforeunload ? "Leave" : "OK") { dialog.answer(true, text) }
                    .buttonStyle(.primaryGlass)
                    .accessibilityIdentifier("page-dialog-accept")
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: 440)
        .chromeContent()
        .floatingPanel()
    }
}

/// What an agent is doing on a page, and what it needs from the user: approve a step, or do it
/// themselves (sign-in, payment). Take Over stops the agent until the page is handed back.
private struct AgentBar: View {
    let pane: BrowserPane

    var body: some View {
        Group {
            if let dialog = pane.dialog {
                DialogCard(dialog: dialog)
            } else if let request = pane.agentRequest {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Label(request.kind == .approve ? "The agent asks" : "Your turn", systemImage: request.kind == .approve ? "hand.raised" : "person.fill.checkmark")
                        .font(DS.Font.banner)
                    Text(request.message)
                        .font(.callout)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(request.kind == .approve ? "Deny" : "Cancel") { request.answer(false) }
                            .buttonStyle(.quiet)
                            .accessibilityIdentifier("agent-deny")
                        Button(request.kind == .approve ? "Allow" : "Done") { request.answer(true) }
                            .buttonStyle(.primaryGlass)
                            .accessibilityIdentifier("agent-allow")
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: 440)
                .chromeContent()
                .floatingPanel()
            } else if pane.userHasControl {
                capsule(dot: DS.Palette.done, text: "You have control") {
                    Button("Hand Back") { pane.userHasControl = false }
                        .accessibilityIdentifier("agent-hand-back")
                }
            } else if let activity = pane.agentActivity {
                capsule(dot: DS.Palette.accent, text: "Agent · \(activity)") {
                    Button("Take Over") { pane.userHasControl = true; pane.agentActivity = nil }
                        .accessibilityIdentifier("agent-take-over")
                }
            }
        }
        .padding(.bottom, DS.Space.l)
        .padding(.horizontal, DS.Space.l)
        .animation(DS.Motion.snappy, value: pane.agentActivity)
        .animation(DS.Motion.snappy, value: pane.userHasControl)
    }

    private func capsule(dot: ChromeStyle, text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: DS.Space.m) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text)
                .font(DS.Font.banner)
                .lineLimit(1)
            Hairline(.vertical)
                .frame(height: 16)
            action()
                .buttonStyle(.quietProminent)
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.xs)
        .padding(.vertical, DS.Space.xs)
        .chromeContent()
        .floatingCapsule(interactive: true)
    }
}
