import DesignSystem
import HostKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Network: how this device reaches its hosts (docs/RELAYS.md) — the way each
/// host's ticket says, direct only (no relay, no third party), or through the user's own
/// `iroh-relay` — and the private CA certificates self-hosted relays chain to.
struct NetworkSettingsSection: View {
    private let hosts = AppModel.shared.hosts
    @State private var mode = RelaySettings.Mode.automatic
    @State private var url = ""
    @State private var token = ""
    @State private var urlProblem: String?
    @State private var failure: String?
    @State private var loaded = false
    @FocusState private var focus: Field?

    private enum Field { case url, token }

    var body: some View {
        Section {
            Picker("Relays", selection: $mode) {
                Text("Default").tag(RelaySettings.Mode.automatic)
                Text("Direct and Local Network Only").tag(RelaySettings.Mode.directOnly)
                Text("Custom Relay").tag(RelaySettings.Mode.custom)
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline)
            #endif
            .labelsHidden()
            .accessibilityIdentifier("settings-relay-mode")
            if mode == .custom {
                TextField("Relay URL", text: $url, prompt: Text(verbatim: "https://relay.example.com"))
                    .font(DS.Font.literal)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .textContentType(.URL)
                    .submitLabel(.done)
                    .focused($focus, equals: .url)
                    .onSubmit(commit)
                    .accessibilityIdentifier("settings-relay-url")
                SecureField("Access Token (Optional)", text: $token)
                    .font(DS.Font.literal)
                    .submitLabel(.done)
                    .focused($focus, equals: .token)
                    .onSubmit(commit)
                    .accessibilityIdentifier("settings-relay-token")
                if let urlProblem {
                    problem(urlProblem).accessibilityIdentifier("settings-relay-url-problem")
                }
            }
            if let failure { problem(failure) }
        } header: {
            Text("Network")
        } footer: {
            Text(footer)
        }
        .onAppear(perform: load)
        .onChange(of: mode) { _, mode in
            commit()
            if mode == .custom, url.isEmpty { focus = .url }
        }
        .onChange(of: focus) { old, _ in if old != nil { commit() } }
        .onDisappear(perform: commit)

        CertificatesSection(hosts: hosts)
    }

    private var footer: String {
        switch mode {
        case .automatic:
            "Each host is reached the way its pairing ticket says: directly when possible, otherwise through its relay."
        case .directOnly:
            "No relay and no third party. Hosts are reachable only on the same network, over Tailscale or over a VPN."
        case .custom:
            "Every host goes through your own iroh-relay instead of the one its ticket names, so your hosts must use it too. Hosts on direct-only tickets stay direct."
        }
    }

    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(DS.Palette.error)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let settings = hosts.relaySettings
        mode = settings.mode
        url = settings.customURL
        token = settings.authToken
    }

    /// Saves what is on screen; open host connections redial with it. A custom relay URL is
    /// checked once editing it ends: an unusable one is kept as typed and says why, and hosts
    /// follow their tickets until it is fixed.
    private func commit() {
        guard loaded else { return }
        var settings = hosts.relaySettings
        settings.mode = mode
        settings.authToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.customURL = typed
        urlProblem = nil
        if mode == .custom, focus != .url, !typed.isEmpty {
            do {
                settings.customURL = try RelayURL.parse(typed).absoluteString
                url = settings.customURL
            } catch {
                urlProblem = error.localizedDescription
            }
        }
        guard settings != hosts.relaySettings else { return }
        do {
            try hosts.setRelaySettings(settings)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The imported CA certificates: subject and expiry, each removable, and Import.
private struct CertificatesSection: View {
    let hosts: HostsModel
    @State private var importing = false
    @State private var failure: String?

    /// `.pem`, `.crt`, `.cer` and `.der` files (the Files app types PEM text as plain text).
    private static let types: [UTType] = [.x509Certificate, .plainText, .data]

    private var certificates: [RelayCertificate] {
        hosts.relaySettings.certificates.compactMap(RelayCertificate.init(der:))
    }

    var body: some View {
        Section {
            ForEach(certificates) { certificate in
                ListRow(Text(certificate.subject), subtitle: expiry(certificate)) {
                    Image(systemName: certificate.isExpired ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        .foregroundStyle(certificate.isExpired ? DS.Palette.error : .secondary)
                } trailing: {
                    Button("Remove", systemImage: "minus.circle.fill", role: .destructive) { remove(certificate) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(DS.Palette.error)
                        .accessibilityIdentifier("settings-relay-ca-remove")
                }
                .accessibilityIdentifier("settings-relay-ca")
                .contextMenu {
                    Button("Remove", systemImage: "trash", role: .destructive) { remove(certificate) }
                }
            }
            Button("Import Certificate…", systemImage: "doc.badge.plus", action: startImport)
                .accessibilityIdentifier("settings-relay-ca-import")
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(DS.Palette.error)
                    .accessibilityIdentifier("settings-relay-ca-error")
            }
        } header: {
            Text("Relay Certificate Authorities")
        } footer: {
            Text("For a self-hosted relay whose certificate comes from your own CA. Only relay connections trust these; the usual public roots stay trusted.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.types, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private func expiry(_ certificate: RelayCertificate) -> Text? {
        guard let expires = certificate.expires else { return nil }
        let date = expires.formatted(date: .abbreviated, time: .omitted)
        return certificate.isExpired ? Text("Expired \(date)").foregroundStyle(DS.Palette.error) : Text("Expires \(date)")
    }

    private func startImport() {
        #if DEBUG
        // `-testRelayCertificate <path>` (UI tests): the Files picker cannot be driven from a
        // test, so Import reads this file as if it had been picked.
        if let path = UserDefaults.standard.string(forKey: "testRelayCertificate") {
            importFiles([URL(fileURLWithPath: path)])
            return
        }
        #endif
        importing = true
    }

    private func importFiles(_ urls: [URL]) {
        do {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { throw RelayCertificate.Problem.unreadable(url.lastPathComponent) }
                _ = try withAnimation(DS.Motion.snappy) { try hosts.importRelayCertificates(data) }
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove(_ certificate: RelayCertificate) {
        do {
            try withAnimation(DS.Motion.snappy) { try hosts.removeRelayCertificate(certificate.der) }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
