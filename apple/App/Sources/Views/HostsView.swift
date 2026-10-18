import HostKit
import PaneLayout
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

/// Home: the "just ssh" field, pairing, ~/.ssh/config import and the hosts, "Needs you" first
/// (04-mobile-ux C1, C2). Functional placeholder for the design layer's Hosts screen.
struct HostsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Called with the target to show.
    let open: (WorkspaceTarget) -> Void

    @State private var destination = ""
    @State private var justSSH: JustSSHFlow?
    @State private var pairing = false
    @State private var importing = false
    @State private var renaming: HostEntry?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("user@host[:port]", text: $destination)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onSubmit(startSSH)
                            .accessibilityIdentifier("ssh-destination")
                        Button("Connect", action: startSSH)
                            .disabled(destination.isEmpty)
                            .accessibilityIdentifier("ssh-connect")
                    }
                } header: {
                    Text("Just SSH")
                }
                if app.hosts.network.isOffline {
                    Label("No network", systemImage: "wifi.slash").foregroundStyle(.secondary)
                }
                if let error = app.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.yellow)
                }
                Section("Hosts") {
                    Button {
                        open(.local)
                    } label: {
                        #if os(macOS)
                        Label("This Mac", systemImage: "desktopcomputer")
                        #else
                        Label("Scratch (local echo)", systemImage: "terminal")
                        #endif
                    }
                    ForEach(app.hosts.entries) { entry in
                        HostRow(entry: entry, install: app.hosts.installs[entry.id])
                            .contentShape(Rectangle())
                            .onTapGesture { open(.host(entry.id)) }
                            .contextMenu { menu(for: entry) }
                            .accessibilityIdentifier("host-\(entry.name)")
                    }
                }
            }
            .navigationTitle("Hosts")
            .toolbar {
                ToolbarItemGroup {
                    Button("Pair", systemImage: "qrcode.viewfinder") { pairing = true }
                        .accessibilityIdentifier("pair-button")
                    Menu("Import", systemImage: "square.and.arrow.down") {
                        #if os(macOS)
                        Button("Read ~/.ssh/config") { readUserConfig() }
                        #endif
                        Button("Choose ssh config file…") { importing = true }
                        Button("Paste ssh config") { pasteConfig() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $justSSH) { flow in
                JustSSHSheet(flow: flow) { id in
                    justSSH = nil
                    open(.host(id))
                }
            }
            .sheet(isPresented: $pairing) {
                PairSheet { id in
                    pairing = false
                    open(.host(id))
                }
            }
            .sheet(isPresented: Binding(get: { !app.hosts.sshConfigAliases.isEmpty }, set: { _ in })) {
                SSHConfigImportSheet()
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                load(config: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
            .alert("Rename Host", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let renaming { app.hosts.rename(renaming.id, to: newName) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    @ViewBuilder private func menu(for entry: HostEntry) -> some View {
        Button("Retry", systemImage: "arrow.clockwise") { app.hosts.connection(entry.id)?.retry() }
        if entry.canInstallHelper {
            Button("Install helper", systemImage: "bolt.horizontal.circle") {
                Task {
                    do {
                        _ = try app.hosts.open(entry.id)
                        try await app.hosts.installHelper(entry.id)
                    } catch {
                        app.lastError = SshErrorText.describe(error)
                    }
                }
            }
        }
        Button(entry.pinned ? "Unpin" : "Pin", systemImage: "pin") { app.hosts.setPinned(entry.id, !entry.pinned) }
        Button("Rename…", systemImage: "pencil") {
            newName = entry.name
            renaming = entry
        }
        Button("Disconnect", systemImage: "bolt.slash") { app.hosts.disconnect(entry.id) }
        Button("Forget", systemImage: "trash", role: .destructive) { app.hosts.remove(entry.id) }
    }

    private func startSSH() {
        let flow = JustSSHFlow(hosts: app.hosts)
        flow.destination = destination
        justSSH = flow
    }

    #if os(macOS)
    private func readUserConfig() {
        do { try app.hosts.loadUserSSHConfig() } catch { app.lastError = SshErrorText.describe(error) }
    }
    #endif

    private func pasteConfig() {
        #if os(iOS)
        load(config: UIPasteboard.general.string ?? "")
        #else
        load(config: NSPasteboard.general.string(forType: .string) ?? "")
        #endif
    }

    private func load(config: String) {
        do { try app.hosts.loadSSHConfig(config) } catch { app.lastError = SshErrorText.describe(error) }
    }
}

extension JustSSHFlow: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

struct HostRow: View {
    let entry: HostEntry
    let install: InstallProgress?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name).font(.body.weight(.medium))
                    if entry.pinned { Image(systemName: "pin.fill").imageScale(.small).foregroundStyle(.secondary) }
                    Text(entry.kind == .daemon ? "helper" : "ssh")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .background(.fill.tertiary, in: .capsule)
                }
                Text(entry.needsYou ?? install?.summary ?? entry.status.summary)
                    .font(.caption)
                    .foregroundStyle(entry.needsYou != nil ? .orange : .secondary)
                    .lineLimit(2)
                Text(entry.address).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.status {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .needsAttention, .offline: .red
        case .idle, .suspended: .gray
        }
    }
}

/// "Just ssh": pick how to authenticate and connect (04-mobile-ux C1).
struct JustSSHSheet: View {
    @Bindable var flow: JustSSHFlow
    let connected: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var importingKey = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("user@host[:port]", text: $flow.destination)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section("Authentication") {
                    Picker("Method", selection: $flow.auth) {
                        Text("Password").tag(JustSSHFlow.AuthChoice.password)
                        ForEach(app.hosts.keys.keys) { key in
                            Text("Key: \(key.label) (\(key.kind == .secureEnclave ? "Secure Enclave" : key.kind.rawValue))")
                                .tag(JustSSHFlow.AuthChoice.key(id: key.id))
                        }
                        #if os(macOS)
                        Text("ssh-agent").tag(JustSSHFlow.AuthChoice.agent)
                        #endif
                    }
                    if flow.auth == .password {
                        SecureField("Password", text: $flow.password)
                            .accessibilityIdentifier("ssh-password")
                        Toggle("Remember password", isOn: $flow.rememberPassword)
                    }
                    Button("Generate new key (ed25519)") { run { try flow.generateKey() } }
                    Button("Generate Secure Enclave key") { run { try flow.generateSecureEnclaveKey() } }
                    Button("Import key file…") { importingKey = true }
                }
                if let key = flow.newKey {
                    Section("Public key: add it to ~/.ssh/authorized_keys on the host") {
                        Text(key.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy public key") { copy(key.publicKey) }
                        Button("Copy install command") { copy(key.authorizeCommand) }
                        if let endpoint = try? flow.endpoint() {
                            Button("Copy ssh-copy-id command") { copy(key.sshCopyIdCommand(for: endpoint)) }
                        }
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                switch flow.step {
                case .failed(let reason): Text(reason).foregroundStyle(.red)
                case .connecting: HStack { ProgressView(); Text("Connecting…") }
                default: EmptyView()
                }
            }
            .navigationTitle("SSH")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        Task {
                            await flow.connect()
                            if case .connected(let id) = flow.step { connected(id) }
                        }
                    }
                    .disabled(flow.step == .connecting)
                    .accessibilityIdentifier("ssh-sheet-connect")
                }
            }
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .plainText, .item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                run { try flow.importKey(pem: try Data(contentsOf: url), passphrase: nil, label: url.lastPathComponent) }
            }
            .modifier(HostKeyPromptModifier(prompts: app.hosts.hostKeyPrompts))
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

func copy(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

/// Pair with a daemon: paste the ticket (`… pair` on the host prints it) or scan its QR code.
struct PairSheet: View {
    let paired: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var ticket = ""
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Ticket") {
                    TextField("pairing ticket", text: $ticket, axis: .vertical)
                        .font(.caption.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("pair-ticket")
                    TextField("Name (optional)", text: $name)
                    #if os(iOS)
                    if QRScannerView.isAvailable {
                        Button("Scan QR code", systemImage: "qrcode.viewfinder") { scanning = true }
                    }
                    #endif
                }
                if let error { Text(error).foregroundStyle(.red) }
                if busy { HStack { ProgressView(); Text("Pairing…") } }
            }
            .navigationTitle("Pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { pair(ticket) }
                        .disabled(ticket.isEmpty || busy)
                        .accessibilityIdentifier("pair-confirm")
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $scanning) {
                QRScannerView { payload in
                    scanning = false
                    ticket = payload
                    pair(payload)
                }
                .ignoresSafeArea()
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 300)
        #endif
    }

    private func pair(_ text: String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let id = try await app.hosts.pair(try PairingTicket(text), name: name.isEmpty ? nil : name)
                paired(id)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Picks hosts from an imported `~/.ssh/config`.
struct SSHConfigImportSheet: View {
    @Environment(AppModel.self) private var app
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(app.hosts.sshConfigAliases, id: \.alias, selection: $selected) { host in
                VStack(alignment: .leading) {
                    Text(host.alias)
                    Text("\(host.user ?? "")@\(host.hostName):\(host.port)\(host.proxyJump.isEmpty ? "" : " via \(host.proxyJump.joined(separator: ","))")")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Import from ssh config")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selected.count)") {
                        app.hosts.importSSHHosts(Array(selected))
                        app.hosts.clearSSHConfigAliases()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { app.hosts.clearSSHConfigAliases() }
                }
            }
        }
        .onAppear { selected = Set(app.hosts.sshConfigAliases.map(\.alias)) }
    }
}

#if os(iOS)
/// The camera QR scanner (VisionKit `DataScannerViewController`). Not available in the
/// simulator; paste or a deep link works there.
struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard !done, let payload = barcode.payloadStringValue, (try? PairingTicket(payload)) != nil else { continue }
                done = true
                scanner.stopScanning()
                found(payload)
            }
        }
    }
}
#endif
