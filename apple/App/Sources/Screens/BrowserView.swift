import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import WebKit

/// In-app browser for localhost previews and links printed in a pane: a floating address capsule
/// at the bottom on iPhone, a top bar on iPad and Mac.
struct BrowserView: View {
    /// The host a dev server page comes from; its data store routes there.
    var routedHost: (id: String, name: String)?
    var onOpenExternally: (URL) -> Void = { _ in }
    var onDone: (() -> Void)?
    var doneTitle = "Done"
    /// Shortcuts are live only while focused.
    var isFocused = true
    var onClose: (() -> Void)?
    var onNavigate: ((URL) -> Void)?
    var onNewTab: (() -> Void)?
    var onOpenAsTab: ((URL) -> Void)?
    var onPointOut: (() -> Void)?
    var onReplays: (() -> Void)?

    @State private var pane: BrowserPane
    /// This view's hold on the page's one `WebView`.
    @State private var hold: BrowserPane.ViewHold
    private var page: any BrowserPageContent { pane.page }
    private var initialURL: URL { pane.initialURL }
    #if DEBUG
    /// UI tests read this to prove the page went through the host.
    @State private var routedCount = 0
    #endif

    /// `intercept` sees each navigation first; returning true stops it.
    init(
        initialURL: URL, dataStore: WKWebsiteDataStore? = nil, routedHost: (id: String, name: String)? = nil,
        intercept: ((URL) -> Bool)? = nil,
        onOpenExternally: @escaping (URL) -> Void = { _ in }, onDone: (() -> Void)? = nil, doneTitle: String = "Done"
    ) {
        let pane = BrowserPane(url: initialURL, hostId: routedHost?.id, dataStore: dataStore)
        pane.intercept = intercept
        self.init(pane: pane, routedHost: routedHost, onOpenExternally: onOpenExternally, onDone: onDone, doneTitle: doneTitle)
    }

    /// A page that outlives the view.
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
    @Environment(\.terminalTheme) private var theme
    @AppStorage(SearchEngine.key) private var engine = SearchEngine.google
    @AppStorage(BrowserAppearance.key) private var appearance = BrowserAppearance.matchTheme
    /// The page's short address until edited.
    @State private var address = ""
    @State private var addressSelection: TextSelection?
    /// -1 when no suggestion is picked.
    @State private var selection = -1
    /// Keeps the start page hidden until the requested page loads or fails.
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
        // size class that flips while the sheet comes up would otherwise make a second one
        // before the first is gone.
        // The regular bar sits above the page, not over it, so the page has no top inset and
        // `BrowserAgent` screenshots start at the document's top.
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
                                .webViewContentBackground(isBlank ? .hidden : .visible)
                                .environment(\.colorScheme, pageScheme)
                        }
                    } else if let popup = pane.popupPage {
                        PopupWebView(page: popup, colorScheme: pageScheme)
                    }
                }
                .ignoresSafeArea(edges: isCompact ? .bottom : [])
                .background(theme.background, ignoresSafeAreaEdges: isCompact ? .bottom : [])
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

    func onOpenAsTab(_ action: @escaping (URL) -> Void) -> BrowserView {
        var view = self
        view.onOpenAsTab = action
        return view
    }

    private var pageScheme: ColorScheme { appearance.scheme(theme: theme.colorScheme) }

    private var isBlank: Bool { (page.url ?? initialURL).absoluteString == "about:blank" }
    private var showsStart: Bool { isBlank && !leavingStart }

    private var startPage: some View {
        let servers = model?.devServers(onHost: pane.hostId)
        return BrowserStartPage(
            hostName: servers?.hostName ?? "", devServers: servers?.ports ?? [],
            // ⌘L may have given the bar's field the keyboard first.
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

    /// A browser leaf reaches its host's `localhost` itself; otherwise go through a forward.
    private func openDevServer(_ port: DetectedPort) {
        if pane.prepare != nil || pane.hostId == nil {
            pick(DevServerRouting.pageURL(for: port))
        } else if let model {
            Task { await model.openPort(port) }
        }
    }

    private var regularBar: some View {
        HStack(spacing: DS.Space.xs) {
            if let onDone {
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

    /// The iPhone bar's capsules plus the gap under them.
    static let compactBarHeight: CGFloat = 44 + DS.Space.s

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
                    .accessibilityIdentifier("browser-more")
                }
            }
            .buttonStyle(.bar)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.s)
        .animation(DS.Motion.snappy, value: isEditing)
    }

    /// A long press lists the history.
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

    private var shortAddress: String { isBlank ? "" : BrowserAddress.display(page.url ?? initialURL) }

    private func showCurrentAddress() {
        address = shortAddress
        addressSelection = nil
    }

    /// Selects the full address so typing replaces it.
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

    /// Keeps the port for local servers, where it matters.
    private var displayHost: String {
        let url = page.url ?? initialURL
        guard let host = url.host() else { return url.absoluteString }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.hasSuffix(".localhost")
        if isLocal, let port = url.port { return "\(host):\(port)" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The host's name when the page is one of its dev servers.
    private var servingHost: String? {
        guard let routedHost, !routedHost.name.isEmpty, let host = (page.url ?? initialURL).host(),
              DevServerNames.isRouted(host) else { return nil }
        return routedHost.name
    }

    private var progressLine: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(DS.Palette.accent)
                .frame(width: geometry.size.width * page.estimatedProgress)
                .animation(DS.Motion.overlay, value: page.estimatedProgress)
        }
        .frame(height: 2)
        .opacity(page.isLoading ? 1 : 0)
        .animation(DS.Motion.overlay, value: page.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

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

/// A browser leaf of a split tree; its page is kept across tab switches.
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
    /// The agent's terminal in the page's tab, if any.
    private var terminal: HostPane? {
        guard let tab = model.composites.tab(containingBrowser: member.id) else { return nil }
        return tab.leaves.lazy.compactMap { tab.members[$0] }.first { $0.hostId != HostGroups.localId }
    }

    /// The next tap on the page picks an element, pasted (not sent) into the terminal.
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

/// What an agent is doing on a page and what it needs from the user. Take Over stops the agent
/// until the page is handed back.
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
