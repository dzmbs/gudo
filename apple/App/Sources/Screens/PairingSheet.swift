import DesignSystem
import HostKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
#if os(iOS)
import VisionKit
#endif

/// Add a host: type `user@host` and sign in ("just ssh"), paste a pairing ticket, or scan the
/// host's QR code. With the real hosts model (`live`) SSH asks how to authenticate and connects
/// at once (04-mobile-ux C1); with mock data it only shows the parsed destination.
struct PairingSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case ssh, ticket, scan
        var id: String { rawValue }

        var title: String {
            switch self {
            case .ssh: "SSH"
            case .ticket: "Ticket"
            case .scan: "Scan"
            }
        }

        /// Scanning needs a camera; the Mac pastes tickets instead.
        static var available: [Mode] {
            #if os(iOS)
            allCases
            #else
            [.ssh, .ticket]
            #endif
        }
    }

    let directory: any HostDirectory
    let live: HostsModel?

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var destination: String
    @State private var ticket = ""
    @State private var isBusy = false
    @State private var showsProgress = false
    @State private var error: String?
    @State private var pairedCount = 0
    @State private var flow: JustSSHFlow?
    @State private var importingKey = false
    @FocusState private var focus: Field?

    private enum Field { case destination, password, ticket }

    init(directory: any HostDirectory, live: HostsModel?, initialMode: Mode = .ssh, destination: String = "") {
        self.directory = directory
        self.live = live
        _mode = State(initialValue: Mode.available.contains(initialMode) ? initialMode : .ssh)
        _destination = State(initialValue: destination)
        _flow = State(initialValue: live.map { hosts in
            let flow = JustSSHFlow(hosts: hosts)
            // A key the app already holds beats a password prompt.
            if let key = hosts.keys.keys.first { flow.auth = .key(id: key.id) }
            return flow
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Method", selection: $mode) {
                        ForEach(Mode.available) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch mode {
                case .ssh:
                    sshSection
                    if let flow, let live { SSHAuthSections(flow: flow, keys: live.keys.keys, importingKey: $importingKey, confirm: confirm) }
                case .ticket: ticketSection
                case .scan: scanSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Host")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: confirm)
                        .disabled(!canConfirm)
                        .accessibilityIdentifier("pairing-confirm")
                }
            }
            .onAppear { focusField() }
            .onChange(of: mode) {
                error = nil
                focusField()
            }
            .sensoryFeedback(DS.Haptic.success, trigger: pairedCount)
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.data, .plainText, .item]) { result in
                guard let flow, case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                run { try flow.importKey(pem: try Data(contentsOf: url), passphrase: nil, label: url.lastPathComponent) }
            }
            .modifier(OptionalHostKeyPrompts(prompts: live?.hostKeyPrompts))
        }
        #if os(iOS)
        .phoneDetents([.medium, .large])
        #else
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420)
        #endif
    }

    // MARK: SSH

    private var parsed: SSHDestination? { SSHDestination(destination) }

    @ViewBuilder private var sshSection: some View {
        Section {
            TextField("user@host:port", text: $destination)
                .font(DS.Font.literal)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .submitLabel(.go)
                .focused($focus, equals: .destination)
                .onSubmit(confirm)
                .accessibilityIdentifier("pairing-destination")
            if let parsed {
                preview("User", parsed.user ?? defaultUser, placeholder: parsed.user == nil)
                preview("Host", parsed.host, placeholder: false)
                preview("Port", parsed.port.map(String.init) ?? "22", placeholder: parsed.port == nil)
            }
        } footer: {
            footer(default: Text(live == nil
                ? "Uses keys from your keychain and ~/.ssh/config. The host key is shown on first connect."
                : "Opens a plain SSH shell at once. Install the helper afterwards to keep sessions running while this device sleeps."))
        }
    }

    private var defaultUser: String {
        #if os(macOS)
        NSUserName()
        #else
        "Required"
        #endif
    }

    private func preview(_ label: String, _ value: String, placeholder: Bool) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(placeholder ? DS.Font.rowSubtitle : DS.Font.literal)
                .foregroundStyle(placeholder ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Ticket

    @ViewBuilder private var ticketSection: some View {
        Section {
            TextEditor(text: $ticket)
                .font(DS.Font.literalSmall)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .focused($focus, equals: .ticket)
                .overlay(alignment: .topLeading) {
                    if ticket.isEmpty {
                        Text("Pairing ticket")
                            .font(DS.Font.literalSmall)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("pairing-ticket")
            Button("Paste", systemImage: "doc.on.clipboard", action: paste)
        } footer: {
            footer(default: Text("Run \(Text(verbatim: "\(Brand.name) pair").font(DS.Font.literalSmall)) on the host to print a ticket and its QR code. Tickets expire after 10 minutes."))
        }
    }

    private func paste() {
        #if canImport(UIKit)
        if let string = UIPasteboard.general.string { ticket = string.trimmingCharacters(in: .whitespacesAndNewlines) }
        #else
        if let string = NSPasteboard.general.string(forType: .string) {
            ticket = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
    }

    // MARK: Scan

    @ViewBuilder private var scanSection: some View {
        Section {
            Viewfinder(scanning: live != nil && !isBusy) { payload in
                ticket = payload
                pair(payload)
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            footer(default: Text(Viewfinder.hasCamera || live == nil
                ? "Pairing starts as soon as the code is in view. The host shows its code with \(Text(verbatim: "\(Brand.name) pair").font(DS.Font.literalSmall))."
                : "This device has no camera for scanning. Paste the ticket instead, or open the pairing link on this device."))
        }
    }

    // MARK: Footer, confirm

    @ViewBuilder
    private func footer(default text: Text) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.error)
                .accessibilityIdentifier("pairing-error")
        } else if showsProgress {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text(mode == .ssh ? "Connecting to \(parsed?.host ?? "host")…" : "Pairing…")
            }
        } else {
            text
        }
    }

    private var confirmTitle: String { mode == .ssh ? "Connect" : "Pair" }

    private var canConfirm: Bool {
        guard !isBusy else { return false }
        switch mode {
        case .ssh: return parsed != nil
        case .ticket: return !ticket.isEmpty
        case .scan: return false
        }
    }

    private func focusField() {
        switch mode {
        case .ssh: focus = .destination
        case .ticket: focus = .ticket
        case .scan: focus = nil
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        error = nil
        switch mode {
        case .ssh:
            guard let flow else {
                directory.quickConnect(destination.trimmingCharacters(in: .whitespaces))
                pairedCount += 1
                dismiss()
                return
            }
            flow.destination = destination
            busy {
                await flow.connect()
                switch flow.step {
                case .connected(let id):
                    pairedCount += 1
                    dismiss()
                    directory.connect(id)
                case .failed(let reason):
                    error = reason
                default:
                    break
                }
            }
        case .ticket:
            pair(ticket)
        case .scan:
            break
        }
    }

    private func pair(_ text: String) {
        busy {
            do {
                let id = try await directory.pair(ticket: text, name: nil)
                pairedCount += 1
                dismiss()
                directory.connect(id)
            } catch {
                self.error = "Couldn't pair: \(error.localizedDescription)"
            }
        }
    }

    /// Runs `work`, showing progress only once it has taken longer than the feedback delay
    private func busy(_ work: @escaping @MainActor () async -> Void) {
        isBusy = true
        Task {
            let progress = Task {
                try await Task.sleep(for: DS.Motion.feedbackDelay)
                showsProgress = true
            }
            await work()
            progress.cancel()
            showsProgress = false
            isBusy = false
        }
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

/// How to sign in to an SSH host: a saved key, a password (saved for reconnects), a new key
/// (ed25519 or Secure Enclave) with its public half to install, or a key file.
private struct SSHAuthSections: View {
    @Bindable var flow: JustSSHFlow
    let keys: [SSHKey]
    @Binding var importingKey: Bool
    let confirm: () -> Void

    var body: some View {
        Section {
            Picker("Sign In With", selection: $flow.auth) {
                Text("Password").tag(JustSSHFlow.AuthChoice.password)
                ForEach(keys) { key in
                    Text(key.label).tag(JustSSHFlow.AuthChoice.key(id: key.id))
                }
                #if os(macOS)
                Text("ssh-agent").tag(JustSSHFlow.AuthChoice.agent)
                #endif
            }
            if flow.auth == .password {
                SecureField("Password", text: $flow.password)
                    .onSubmit(confirm)
                    .accessibilityIdentifier("ssh-password")
                Toggle("Remember Password", isOn: $flow.rememberPassword)
            }
            Menu {
                Button("Generate Key (ed25519)", systemImage: "key") { run { try flow.generateKey() } }
                Button("Generate Secure Enclave Key", systemImage: "lock.shield") { run { try flow.generateSecureEnclaveKey() } }
                Button("Import Key File…", systemImage: "doc.badge.plus") { importingKey = true }
            } label: {
                Label("New Key", systemImage: "key.badge.plus")
            }
        } header: {
            SectionTitle("Authentication")
        }
        if let key = flow.newKey {
            Section {
                Text(key.publicKey)
                    .font(DS.Font.literalSmall)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .truncationMode(.middle)
                Button("Copy Public Key", systemImage: "doc.on.doc") { copy(key.publicKey) }
                Button("Copy Install Command", systemImage: "terminal") { copy(key.authorizeCommand) }
                if let endpoint = try? flow.endpoint() {
                    Button("Copy ssh-copy-id Command", systemImage: "terminal") { copy(key.sshCopyIdCommand(for: endpoint)) }
                }
            } header: {
                SectionTitle("Public key")
            } footer: {
                Text("Add it to ~/.ssh/authorized_keys on the host, or connect once with a password and install it from there.")
            }
        }
    }

    private func run(_ body: () throws -> Void) {
        try? body()
    }
}

/// Host-key prompts presented from inside a sheet (an alert on the window under it would not
/// show while the sheet is up).
private struct OptionalHostKeyPrompts: ViewModifier {
    let prompts: HostKeyPrompts?

    func body(content: Content) -> some View {
        if let prompts {
            content.modifier(HostKeyPromptModifier(prompts: prompts))
        } else {
            content
        }
    }
}

/// `[user@]host[:port]`, parsed as typed.
private struct SSHDestination {
    var user: String?
    var host: String
    var port: Int?

    init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.hasPrefix("ssh ") { rest = rest.dropFirst(4) }
        if let at = rest.lastIndex(of: "@") {
            let user = rest[..<at]
            guard !user.isEmpty else { return nil }
            self.user = String(user)
            rest = rest[rest.index(after: at)...]
        }
        if let colon = rest.lastIndex(of: ":") {
            let portText = rest[rest.index(after: colon)...]
            if let port = Int(portText), (1...65535).contains(port) {
                self.port = port
                rest = rest[..<colon]
            } else if !portText.isEmpty {
                return nil
            } else {
                rest = rest[..<colon]
            }
        }
        guard !rest.isEmpty, !rest.contains(" ") else { return nil }
        host = String(rest)
    }
}

/// The camera viewfinder: VisionKit's live QR scanner behind corner brackets where a camera
/// exists, else a dark square with the brackets and a hint.
private struct Viewfinder: View {
    /// Whether to run the camera (the real hosts model is present and nothing is pairing).
    let scanning: Bool
    let found: (String) -> Void

    static var hasCamera: Bool {
        #if os(iOS)
        QRScannerView.isAvailable
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(.black)
            #if os(iOS)
            if scanning, Self.hasCamera {
                QRScannerView(found: found)
                    .clipShape(.rect(cornerRadius: DS.Radius.panel))
            }
            #endif
            CornerBrackets()
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(48)
            if !(scanning && Self.hasCamera) {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 36, weight: .light))
                    Text(Self.hasCamera || !scanning ? "Point at the QR code shown by the host" : "No camera available")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 72)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera viewfinder. Point at the QR code shown by the host.")
    }
}

nonisolated private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(rect.width, rect.height) * 0.16
        var path = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0), (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0), (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }
}

/// Picks hosts from an imported ssh_config (aliases with their resolved address).
struct SSHConfigImportSheet: View {
    let hosts: HostsModel
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(hosts.sshConfigAliases, id: \.alias, selection: $selected) { host in
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.alias).font(DS.Font.rowTitleEmphasis)
                    Text("\(host.user.map { "\($0)@" } ?? "")\(host.hostName):\(host.port)\(host.proxyJump.isEmpty ? "" : " via \(host.proxyJump.joined(separator: ", "))")")
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("Import Hosts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selected.count)") {
                        hosts.importSSHHosts(Array(selected))
                        hosts.clearSSHConfigAliases()
                    }
                    .disabled(selected.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { hosts.clearSSHConfigAliases() }
                }
            }
        }
        .onAppear { selected = Set(hosts.sshConfigAliases.map(\.alias)) }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
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
                guard !done, let payload = barcode.payloadStringValue,
                      (try? PairingTicket(payload)) != nil || URL(string: payload).flatMap(PairingTicket.init(url:)) != nil
                else { continue }
                done = true
                scanner.stopScanning()
                found(payload)
            }
        }
    }
}
#endif
