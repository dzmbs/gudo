import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import WebKit

/// In-app browser for localhost previews and links printed in a pane. Safari 26's layout: a
/// floating glass address capsule at the bottom on iPhone; a compact 36 pt top bar on iPad and Mac.
/// The page itself stays edge to edge; glass is only on the controls.
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
    /// The sheet's page moves into a browser tab.
    var onOpenAsTab: ((URL) -> Void)?
    /// The user points at an element for the agent beside the page.
    var onPointOut: (() -> Void)?

    @State private var pane: BrowserPane
    private var page: WebPage { pane.page }
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
        onPointOut: (() -> Void)? = nil
    ) {
        self.isFocused = isFocused
        self.onPointOut = onPointOut
        self.onClose = onClose
        self.onNavigate = onNavigate
        self.routedHost = routedHost
        self.onOpenExternally = onOpenExternally
        self.onDone = onDone
        self.doneTitle = doneTitle
        _pane = State(initialValue: pane)
    }
    @Environment(\.terminalTheme) private var theme
    @State private var address = ""
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
                progressLine
            }
            WebView(page)
                .ignoresSafeArea(edges: isCompact ? .bottom : [])
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isCompact { compactBar }
                }
        }
            .overlay(alignment: .top) {
                if isCompact { progressLine }
            }
        .onAppear { pane.start() }
        .onChange(of: page.url) { _, url in
            if !isEditing { address = url?.absoluteString ?? "" }
            if let url { onNavigate?(url) }
        }
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

    // MARK: Bars

    /// iPad and Mac: back, forward, reload, address field, open externally.
    private var regularBar: some View {
        HStack(spacing: DS.Space.xs) {
            if let onDone {
                Button(doneTitle, action: onDone)
                    .labelStyle(.titleOnly)
                    .buttonStyle(.borderless)
                    .padding(.trailing, DS.Space.s)
                    .accessibilityIdentifier("browser-done")
            }
            if let onClose {
                Button("Close Page", systemImage: "xmark", action: onClose)
                    .help("Close Page")
                    .accessibilityIdentifier("browser-close")
            }
            navigationButtons
            reloadButton
            addressField
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            shareButton
            if let onPointOut {
                Button("Point Out to Agent", systemImage: "hand.point.up.left", action: onPointOut)
                    .help("Point Out to Agent")
                    .accessibilityIdentifier("browser-point-out")
            }
            if let onOpenAsTab {
                Button("Open as Tab", systemImage: "plus.square.on.square") { onOpenAsTab(page.url ?? initialURL) }
                    .help("Open as Tab")
                    .accessibilityIdentifier("browser-open-tab")
            }
            Button("Open in Safari", systemImage: "safari", action: openExternally)
                .help("Open in Safari")
        }
        .buttonStyle(.bar)
        .padding(.horizontal, DS.Space.s)
        .frame(height: DS.Size.tabBar)
        .background(theme.background)
        .overlay(alignment: .bottom) { theme.splitDivider.frame(height: 1) }
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
                if !isEditing {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                        if let url = page.url {
                            ShareLink(item: url)
                        }
                        if let onPointOut {
                            Button("Point Out to Agent", systemImage: "hand.point.up.left", action: onPointOut)
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

    @ViewBuilder private var navigationButtons: some View {
        Button("Back", systemImage: "chevron.backward") {
            if let item = page.backForwardList.backList.last { page.load(item) }
        }
        .disabled(page.backForwardList.backList.isEmpty)
        .keyboardShortcut(isFocused ? KeyboardShortcut("[", modifiers: .command) : nil)
        Button("Forward", systemImage: "chevron.forward") {
            if let item = page.backForwardList.forwardList.first { page.load(item) }
        }
        .disabled(page.backForwardList.forwardList.isEmpty)
        .keyboardShortcut(isFocused ? KeyboardShortcut("]", modifiers: .command) : nil)
    }

    private var reloadButton: some View {
        Button(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
            if page.isLoading { page.stopLoading() } else { page.reload() }
        }
        .keyboardShortcut(isFocused ? KeyboardShortcut("r", modifiers: .command) : nil)
        .contentTransition(.symbolEffect(.replace))
    }

    @ViewBuilder private var shareButton: some View {
        if let url = page.url {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    // MARK: Address

    private var addressField: some View {
        ZStack {
            if isEditing {
                TextField("Search or enter address", text: $address)
                    .font(DS.Font.literal)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    #endif
                    .focused($isEditing)
                    .onSubmit(go)
                    .onKeyPress(.escape) {
                        isEditing = false
                        return .handled
                    }
                    .padding(.horizontal, DS.Space.m)
            } else {
                Button {
                    address = page.url?.absoluteString ?? initialURL.absoluteString
                    isEditing = true
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        if (page.url ?? initialURL).scheme == "https" {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(displayHost)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let servingHost {
                            Text(servingHost)
                                .font(DS.Font.literalSmall)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DS.Space.m)
                    .frame(maxHeight: .infinity)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Address, \(displayHost)" + (servingHost.map { ", on \($0)" } ?? ""))
            }
        }
        .frame(minHeight: 28)
        .floatingCapsule(interactive: true)
        .keyboardShortcut(isFocused ? KeyboardShortcut("l", modifiers: .command) : nil)
        .accessibilityIdentifier("browser-address")
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

    /// A 2 pt accent line that fills while loading and fades when done.
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
        let input = address.trimmingCharacters(in: .whitespaces)
        isEditing = false
        guard !input.isEmpty else { return }
        let url: URL?
        if input.contains("://") {
            url = URL(string: input)
        } else if input.contains(".") || input.hasPrefix("localhost") || input.contains(":") {
            url = URL(string: (input.hasPrefix("localhost") || input.hasPrefix("127.") ? "http://" : "https://") + input)
        } else {
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: input)]
            url = components?.url
        }
        if let url { page.load(URLRequest(url: url)) }
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
                    onPointOut: terminal == nil ? nil : { pointOut(pane) })
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
            _ = try? await pane.page.callJavaScript("return window.__un.pick()", contentWorld: BrowserAgentScript.world)
            var picked = ""
            for _ in 0..<600 where picked.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
                picked = (try? await pane.page.callJavaScript("return window.__un.picked()", contentWorld: BrowserAgentScript.world) as? String) ?? ""
            }
            guard !picked.isEmpty else { return }
            daemon.paste("In the browser beside you: " + picked.replacingOccurrences(of: "\n", with: " ") + " ", into: terminal.pane.rawValue)
            model.toasts.show(Toast("Pointed out to the terminal", systemImage: "checkmark.circle.fill", style: .success))
        }
    }
}

/// What an agent is doing on a page, and what it needs from the user: approve a step, or do it
/// themselves (sign-in, payment). Take Over stops the agent until the page is handed back.
private struct AgentBar: View {
    let pane: BrowserPane

    var body: some View {
        Group {
            if let request = pane.agentRequest {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Label(request.kind == .approve ? "The agent asks" : "Your turn", systemImage: request.kind == .approve ? "hand.raised" : "person.fill.checkmark")
                        .font(.callout.weight(.semibold))
                    Text(request.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(request.kind == .approve ? "Deny" : "Cancel") { request.answer(false) }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("agent-deny")
                        Button(request.kind == .approve ? "Allow" : "Done") { request.answer(true) }
                            .buttonStyle(.primaryGlass)
                            .accessibilityIdentifier("agent-allow")
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: 440)
                .floatingCapsule(interactive: true)
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
                .font(.callout.weight(.medium))
                .lineLimit(1)
            action()
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.s)
        .padding(.vertical, DS.Space.s)
        .floatingCapsule(interactive: true)
    }
}
