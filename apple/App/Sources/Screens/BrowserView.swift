import DesignSystem
import SwiftUI
import WebKit

/// In-app browser for localhost previews and links printed in a pane. Safari 26's layout: a
/// floating glass address capsule at the bottom on iPhone; a compact 36 pt top bar on iPad and Mac.
/// The page itself stays edge to edge; glass is only on the controls.
struct BrowserView: View {
    var initialURL: URL
    var onOpenExternally: (URL) -> Void = { _ in }

    @State private var page = WebPage()
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
        Group {
            if isCompact {
                WebView(page)
                    .ignoresSafeArea(edges: .bottom)
                    .safeAreaInset(edge: .bottom, spacing: 0) { compactBar }
                    .overlay(alignment: .top) { progressLine }
            } else {
                VStack(spacing: 0) {
                    regularBar
                    progressLine
                    WebView(page)
                }
            }
        }
        .onAppear {
            if page.url == nil { page.load(URLRequest(url: initialURL)) }
        }
        .onChange(of: page.url) { _, url in
            if !isEditing { address = url?.absoluteString ?? "" }
        }
    }

    // MARK: Bars

    /// iPad and Mac: back, forward, reload, address field, open externally.
    private var regularBar: some View {
        HStack(spacing: DS.Space.xs) {
            navigationButtons
            reloadButton
            addressField
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            shareButton
            Button("Open in Default Browser", systemImage: "safari", action: openExternally)
                .help("Open in Default Browser")
        }
        .buttonStyle(.bar)
        .padding(.horizontal, DS.Space.s)
        .frame(height: DS.Size.tabBar)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// iPhone: one floating glass capsule with the controls around the address.
    private var compactBar: some View {
        GlassEffectContainer(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                if !isEditing {
                    HStack(spacing: 0) {
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
                        Button("Open in Safari", systemImage: "safari", action: openExternally)
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
        .keyboardShortcut("[", modifiers: .command)
        Button("Forward", systemImage: "chevron.forward") {
            if let item = page.backForwardList.forwardList.first { page.load(item) }
        }
        .disabled(page.backForwardList.forwardList.isEmpty)
        .keyboardShortcut("]", modifiers: .command)
    }

    private var reloadButton: some View {
        Button(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
            if page.isLoading { page.stopLoading() } else { page.reload() }
        }
        .keyboardShortcut("r", modifiers: .command)
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
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DS.Space.m)
                    .frame(maxHeight: .infinity)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Address, \(displayHost)")
            }
        }
        .frame(minHeight: 28)
        .floatingCapsule(interactive: true)
        .keyboardShortcut("l", modifiers: .command)
        .accessibilityIdentifier("browser-address")
    }

    /// `github.com`, or `localhost:5173` for local servers (the port matters there).
    private var displayHost: String {
        let url = page.url ?? initialURL
        guard let host = url.host() else { return url.absoluteString }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        if isLocal, let port = url.port { return "\(host):\(port)" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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
