import DesignSystem
import SwiftUI

/// The browser sheet: the dev servers the host is running (detected listening ports), and the
/// page once one is open, through a forward to the host's `localhost:<port>`.
struct BrowserSheet: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let url = model.browserURL {
                BrowserView(initialURL: url, onDone: { withAnimation(DS.Motion.snappy) { model.browserURL = nil } }, doneTitle: "Ports")
                    .id(url)
            } else {
                NavigationStack {
                    PortsList()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .macMinimumSize(width: 720, height: 520)
        .presentationSizing(.page)
    }
}

/// Listening ports on the host, HTTP first: tap to open in the in-app browser.
struct PortsList: View {
    @Environment(WindowModel.self) private var model
    @Environment(\.terminalTheme) private var theme
    @State private var address = ""
    @State private var opening: UInt16?

    private var ports: [DetectedPort] { model.ports.ports }

    var body: some View {
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
                    TextField("Address or localhost port", text: $address)
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
        .navigationTitle("Ports")
        .navigationSubtitle(model.ports.hostName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .animation(DS.Motion.snappy, value: ports)
        .accessibilityIdentifier("ports-list")
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
            await model.openPort(port)
        }
    }

    private func openAddress() {
        let input = address.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        // A bare port or localhost:port goes through a forward to the host.
        let digits = input.replacingOccurrences(of: "localhost:", with: "").replacingOccurrences(of: "http://", with: "")
        if let number = UInt16(digits.split(separator: "/").first ?? "") {
            open(DetectedPort(port: number, process: "", url: nil, isHTTP: true, loopbackOnly: true, pane: nil))
            return
        }
        let url = URL(string: input.contains("://") ? input : "https://" + input)
        if let url { withAnimation(DS.Motion.snappy) { model.browserURL = url } }
    }
}

/// "localhost:5173 is up · Open": offered once when a pane starts a server on the window's host.
struct PortOfferBanner: ViewModifier {
    let model: WindowModel

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let port = model.ports.offer, !model.isEditorShown {
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
                .frame(maxWidth: 520)
                .floatingCapsule()
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
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
    /// The "a dev server is up" offer for a window.
    func portOffers(_ model: WindowModel) -> some View {
        modifier(PortOfferBanner(model: model))
    }
}

extension WindowModel {
    /// Forwards a host port and shows it in the in-app browser.
    func openPort(_ port: DetectedPort) async {
        do {
            let url = try await ports.open(port)
            ports.dismissOffer()
            browserURL = url
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

    /// A URL from a pane (links sheet): http(s) on localhost goes through a forward when the
    /// window's host has that port; other URLs open in the in-app browser as they are.
    func openURL(_ text: String) async {
        guard let url = URL(string: text) else { return }
        if let host = url.host(), ["localhost", "127.0.0.1", "0.0.0.0"].contains(host), let port = url.port, workspace?.isRemote == true {
            var detected = ports.ports.first { $0.port == UInt16(port) }
                ?? DetectedPort(port: UInt16(port), process: "", url: nil, isHTTP: true, loopbackOnly: true, pane: nil)
            detected.url = text
            await openPort(detected)
            return
        }
        browserURL = url
        sheet = .browser
    }
}
