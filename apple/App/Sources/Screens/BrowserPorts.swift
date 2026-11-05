import DesignSystem
import SwiftUI

/// The host's listening ports, and a page once one is open through a forward to its `localhost`.
struct BrowserSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isToolWindow) private var isToolWindow

    var body: some View {
        Group {
            if let url = model.browserURL {
                BrowserView(
                    initialURL: url, dataStore: DevServerRouting.shared.dataStore(forHost: model.browserHost),
                    routedHost: model.browserHost.map { (id: $0, name: model.ports.hostName) },
                    intercept: model.browserSignInPane == nil ? nil : { [model] in model.pastedSignInCode($0) },
                    onDone: { withAnimation(DS.Motion.snappy) { model.browserURL = nil } }, doneTitle: "Ports")
                    .onOpenAsTab { [model] url in model.openBrowser(url, hostId: model.browserHost, placement: .tab) }
                    .id("\(model.browserHost ?? "")|\(url)")
            } else {
                NavigationStack {
                    PortsList()
                        .toolbar {
                            if !isToolWindow {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { dismiss() }
                                }
                            }
                        }
                }
            }
        }
        .toolMinimumSize(width: 720, height: 520)
        .presentationSizing(.page)
    }
}

/// Listening ports on the host, HTTP first: tap to open in the in-app browser.
struct PortsList: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @State private var address = ""
    @State private var opening: UInt16?
    /// The Ports leaf this list is in; pages open beside it.
    @Environment(\.toolLeaf) private var leaf

    private var ports: [DetectedPort] { model.ports.ports }

    var body: some View {
        Group {
            if let reason = model.ports.unavailableReason {
                EmptyState("No Helper Running", systemImage: "point.3.connected.trianglepath.dotted", message: reason) {
                    Button("Show Hosts") { model.showHosts() }
                        .buttonStyle(.glass)
                }
                .chromeContent()
            } else {
                list
            }
        }
        // On the content only: over the chrome it would rename the leaf's own Close button.
        .accessibilityIdentifier("ports-list")
        .toolChrome("Ports", subtitle: model.ports.hostName)
        .animation(DS.Motion.snappy, value: ports)
    }

    private var list: some View {
        List {
            Section {
                ForEach(ports.filter(\.isHTTP)) { port in row(port) }
            } header: {
                SectionTitle("Dev servers", count: ports.filter(\.isHTTP).count)
            } footer: {
                if ports.isEmpty {
                    Text("Start a server in a pane (`npm run dev`, `python3 -m http.server`) and it shows up here by itself.")
                }
            }
            .chromeRows()
            let other = ports.filter { !$0.isHTTP }
            if !other.isEmpty {
                Section {
                    ForEach(other) { port in row(port) }
                } header: {
                    SectionTitle("Other ports", count: other.count)
                }
                .chromeRows()
            }
            Section {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    // A literal once typed; the prompt is prose.
                    TextField("Address", text: $address, prompt: Text("Address or localhost port").font(.body))
                        .font(DS.Font.literal)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        #endif
                        .onSubmit(openAddress)
                        .accessibilityIdentifier("ports-address")
                }
            } header: {
                SectionTitle("Open")
            }
            .chromeRows()
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .chromeGrouped()
    }

    private func row(_ port: DetectedPort) -> some View {
        Button { open(port) } label: {
            ListRow(
                Text(verbatim: "localhost:\(port.port)").font(DS.Font.literal.weight(.medium)),
                subtitle: Text(subtitle(port)),
                leading: {
                    if opening == port.port {
                        Spinner().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: port.isHTTP ? "globe" : "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(port.isHTTP ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(.secondary))
                    }
                }
            ) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("port-\(port.port)")
        .contextMenu {
            Button("Open", systemImage: "safari") { open(port) }
            Button("Copy Address", systemImage: "doc.on.doc") { FilesPasteboard.copy("localhost:\(port.port)") }
        }
    }

    private func subtitle(_ port: DetectedPort) -> String {
        var parts = [port.process]
        if let pane = port.pane { parts.append(pane) }
        if !port.loopbackOnly { parts.append("all interfaces") }
        return parts.joined(separator: " · ")
    }

    private func open(_ port: DetectedPort) {
        opening = port.port
        Task {
            defer { opening = nil }
            await model.openPort(port, besideTool: leaf?.member.id)
        }
    }

    private func openAddress() {
        let input = address.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        let digits = input.replacingOccurrences(of: "localhost:", with: "").replacingOccurrences(of: "http://", with: "")
        if let number = UInt16(digits.split(separator: "/").first ?? "") {
            open(DetectedPort(port: number, process: "", url: nil, isHTTP: true, loopbackOnly: true, pane: nil))
            return
        }
        guard let url = URL(string: input.contains("://") ? input : "https://" + input) else { return }
        if model.opensToolsAsLeaves {
            model.openPage(url, hostId: nil, besideTool: leaf?.member.id)
        } else {
            withAnimation(DS.Motion.snappy) { model.browserURL = url }
        }
    }
}

/// Offered once when a pane starts a server on the window's host. Sits at the bottom so it never
/// covers a page's address bar.
struct PortOfferBanner: ViewModifier {
    let model: WindowModel
    /// Exposed so other banners can sit above it.
    static let height: CGFloat = 52

    /// Clear of the iPhone's tab bar and, while a page is in front there, of its address bar.
    static func bottomInset(_ model: WindowModel) -> CGFloat {
        guard model.widthBucket == .compact else { return DS.Space.l }
        return 64 + (model.activeMixed?.focusedBrowser != nil ? BrowserView.compactBarHeight : 0)
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomLeading) {
            if let port = model.ports.offer, !model.editorHasKeys {
                HStack(spacing: DS.Space.m) {
                    Circle()
                        .fill(DS.Palette.done)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "localhost:\(port.port) is up")
                            .font(DS.Font.literal.weight(.medium))
                        Text(port.pane.map { "\(port.process) · \($0)" } ?? port.process)
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button("Open") { Task { await model.openPort(port) } }
                        .buttonStyle(.primaryGlass)
                        .controlSize(.small)
                        .accessibilityIdentifier("port-offer-open")
                    Button("Dismiss", systemImage: "xmark") { withAnimation(DS.Motion.overlay) { model.ports.dismissOffer() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bar)
                }
                .padding(.leading, DS.Space.l)
                .padding(.trailing, DS.Space.s)
                .padding(.vertical, DS.Space.s)
                .frame(minHeight: Self.height)
                .chromeContent()
                .floatingCapsule()
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, DS.Space.l)
                .padding(.bottom, Self.bottomInset(model))
                .movingTransition(.bottom)
                .task(id: port.port) {
                    try? await Task.sleep(for: .seconds(15))
                    withAnimation(DS.Motion.overlay) { model.ports.dismissOffer() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("port-offer")
            }
        }
        .animation(DS.Motion.overlay, value: model.ports.offer)
    }
}

extension View {
    func portOffers(_ model: WindowModel) -> some View {
        modifier(PortOfferBanner(model: model))
    }
}

extension WindowModel {
    /// The window host's HTTP ports, when `hostId` is that host.
    func devServers(onHost hostId: String?) -> (hostName: String, ports: [DetectedPort]) {
        guard let hostId, ports.hostId == hostId else { return ("", []) }
        return (ports.hostName, ports.ports.filter(\.isHTTP))
    }

    /// Where tools are leaves, a page leaf reaches the host's `localhost` itself; otherwise the
    /// browser sheet goes through a forward. `besideTool` is the Ports leaf to open beside.
    func openPort(_ port: DetectedPort, besideTool tool: UUID? = nil) async {
        if opensToolsAsLeaves {
            ports.dismissOffer()
            openPage(DevServerRouting.pageURL(for: port), hostId: ports.hostId, besideTool: tool)
            return
        }
        do {
            let url = try await ports.open(port)
            ports.dismissOffer()
            browserURL = url
            browserHost = ports.hostId
            if sheet != .browser {
                if sheet != nil {
                    sheet = nil
                    try? await Task.sleep(for: .milliseconds(450))
                }
                sheet = .browser
            }
        } catch {
            toasts.show(Toast("Couldn't open localhost:\(port.port): \(ScreenError.describe(error))", systemImage: "exclamationmark.triangle.fill", style: .failure))
        }
    }

    /// A URL from a pane. A remote host's dev server URL goes through a forward; others open as they are.
    func openURL(_ text: String) async {
        guard let url = URL(string: text) else { return }
        if isDevServerURL(url), let port = url.port, workspace?.isRemote == true {
            var detected = ports.ports.first { $0.port == UInt16(port) }
                ?? DetectedPort(port: UInt16(port), process: "", url: nil, isHTTP: true, loopbackOnly: true, pane: nil)
            detected.url = text
            await openPort(detected)
            return
        }
        // A remote pane's link is the host's: a `file:` URL would show this device's file to
        // the host's agent beside it.
        if workspace?.isRemote == true, !HostLinks.mayOpen(url) { return }
        openPage(url, hostId: nil)
    }

    /// Where tools are leaves, a page leaf beside `tool` (or the focused leaf), reusing one already
    /// showing the URL; otherwise the browser sheet.
    func openPage(_ url: URL, hostId: String?, besideTool tool: UUID? = nil) {
        guard opensToolsAsLeaves else {
            browserURL = url
            browserHost = hostId
            if sheet != .browser { sheet = .browser }
            return
        }
        if let tool, let tab = composites.tab(containingTool: tool), let leaf = tab.leaf(forTool: tool) {
            focusLeaf(leaf, inMixedTab: tab.id)
        }
        if let mixed = activeMixed, let leaf = mixed.leaves.first(where: { candidate in
            mixed.browsers[candidate].map { $0.url == url.absoluteString && $0.hostId == hostId } ?? false
        }) {
            focusLeaf(leaf, inMixedTab: mixed.id)
            return
        }
        openBrowser(url, hostId: hostId, placement: .split)
    }
}
