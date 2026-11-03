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
/// at once; with mock data it only shows the parsed destination.
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
    @State private var camera = CameraAccess()
    @State private var importingKey = false
    @FocusState private var focus: Field?

    private enum Field { case destination, password, ticket }

    /// A ticket from a pairing link: shown with its host for the user to confirm.
    let linkTicket: String

    init(directory: any HostDirectory, live: HostsModel?, initialMode: Mode = .ssh, destination: String = "", ticket: String = "") {
        self.directory = directory
        self.live = live
        linkTicket = ticket
        _mode = State(initialValue: ticket.isEmpty ? (Mode.available.contains(initialMode) ? initialMode : .ssh) : .ticket)
        _destination = State(initialValue: destination)
        _ticket = State(initialValue: ticket)
        _flow = State(initialValue: live.map { hosts in
            let flow = JustSSHFlow(hosts: hosts)
            // A key the app already holds beats a password prompt.
            if let key = hosts.keys.keys.first { flow.auth = .key(id: key.id) }
            return flow
        })
    }

    var body: some View {
        SheetScaffold(
            "Add Host",
            cancel: SheetAction("Cancel") { dismiss() },
            primary: mode == .scan ? nil : SheetAction(confirmTitle, isEnabled: canConfirm, identifier: "pairing-confirm", action: confirm),
            // On the Mac, Paste sits on the buttons' line, as in the system's own sheets.
            accessory: {
                #if os(macOS)
                if mode == .ticket {
                    Button("Paste", systemImage: "doc.on.clipboard", action: paste)
                }
                #endif
            }
        ) {
            Form {
                switch mode {
                case .ssh:
                    sshSection.chromeRows()
                    if let flow, let live { SSHAuthSections(flow: flow, keys: live.keys.keys, importingKey: $importingKey, confirm: confirm).chromeRows() }
                case .ticket: ticketSection.chromeRows()
                case .scan: scanSection
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            #if os(macOS)
            // On the page above the form's cards, centred like a window's tab control.
            .safeAreaInset(edge: .top, spacing: 0) {
                methodPicker
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                    .padding(.top, DS.Space.m)
            }
            #else
            // Under the navigation bar, part of it: the form scrolls beneath both.
            .safeAreaBar(edge: .top) {
                methodPicker
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.bottom, DS.Space.s)
            }
            #endif
            .macFittedForm(maxHeight: 520, step: formStep)
            .onAppear { focusField() }
            .onChange(of: mode) {
                error = nil
                focusField()
            }
            // Another link while the sheet is up replaces what it shows.
            .onChange(of: linkTicket) { _, newTicket in
                guard !newTicket.isEmpty else { return }
                ticket = newTicket
                error = nil
                mode = .ticket
                focus = nil
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
        // Full height: the host to confirm, the link's warning and any error sit under the
        // field, below a half sheet's fold on a phone.
        .phoneDetents([.large])
        #else
        // Sized per mode only; content that arrives later (a new public key, an error) scrolls.
        .frame(width: 500, height: macHeight)
        .animation(DS.Motion.snappy, value: mode)
        #endif
    }

    #if os(macOS)
    private var macHeight: CGFloat {
        switch mode {
        case .ssh: live == nil ? 340 : 590
        case .ticket, .scan: 350
        }
    }
    #endif

    private var methodPicker: some View {
        Picker("Method", selection: $mode) {
            ForEach(Mode.available) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: SSH

    private var parsed: SSHDestination? { SSHDestination(destination) }

    @ViewBuilder private var sshSection: some View {
        Section {
            // Prompt only: the address reads from the leading edge, as typed.
            TextField("Address", text: $destination, prompt: Text("user@host:port"))
                .labelsHidden()
                .textFieldStyle(.plain)
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
            // Always there, the defaults standing in until typed: the form keeps its shape.
            preview("User", parsed?.user ?? defaultUser, placeholder: parsed?.user == nil)
            preview("Host", parsed?.host ?? "Required", placeholder: parsed == nil)
            preview("Port", parsed?.port.map(String.init) ?? "22", placeholder: parsed?.port == nil)
            if isTailnet {
                LabeledContent("Network") {
                    HStack(spacing: DS.Space.xs) {
                        TailscaleTag()
                        Text("needs Tailscale connected here")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("pairing-tailscale")
            }
        } footer: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                footer(default: Text(live == nil
                    ? "Uses keys from your keychain and ~/.ssh/config. The host key is shown on first connect."
                    : "Opens a plain SSH shell at once. Install the helper afterwards to keep sessions running while this device sleeps."))
                if error != nil, isTailnet {
                    TailscaleHint()
                }
            }
        }
    }

    /// Changes that add or remove rows: the sheet may resize for these only.
    private var formStep: [AnyHashable] {
        [mode, isTailnet, (try? PairingTicket(ticket)) != nil, !linkTicket.isEmpty && ticket == linkTicket, error != nil, flow?.auth]
    }

    /// The destination is a tailnet address or MagicDNS name (100.64.0.0/10, `*.ts.net`).
    private var isTailnet: Bool { parsed.map { Tailscale.isTailnet(host: $0.host) } ?? false }

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
                .foregroundStyle(placeholder ? DS.Palette.textTertiary : DS.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Ticket

    @ViewBuilder private var ticketSection: some View {
        Section {
            // The field's own placeholder, so it and the caret share one inset.
            TextField("Ticket", text: $ticket, prompt: Text("Pairing ticket"), axis: .vertical)
                .labelsHidden()
                // A pasted ticket scrolls inside its lines rather than growing the form.
                .lineLimit(5, reservesSpace: true)
                .textFieldStyle(.plain)
                .font(DS.Font.literalSmall)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focus, equals: .ticket)
                .accessibilityIdentifier("pairing-ticket")
            #if os(iOS)
            Button("Paste", systemImage: "doc.on.clipboard", action: paste)
            #endif
            if let parsed = try? PairingTicket(ticket) {
                ticketHost(parsed)
                ticketRelay(parsed)
            }
        } footer: {
            if !linkTicket.isEmpty, ticket == linkTicket {
                footer(default: Text("A link opened this ticket. Pair only with a host you set up: it will see what you type in its terminals and can show you web pages."))
            } else {
                footer(default: Text("Run \(Text(verbatim: "\(Brand.daemonBinary) pair").font(DS.Font.literalSmall)) on the host to print a ticket and its QR code. Tickets expire after 10 minutes."))
            }
        }
    }

    /// Which host the ticket is for: the host already paired with it, or its key's start
    /// (what `<brand> pair` prints on the host).
    private func ticketHost(_ parsed: PairingTicket) -> some View {
        let known = live?.records.first { $0.daemonId == parsed.info.daemonId }
        return LabeledContent {
            VStack(alignment: .trailing, spacing: 1) {
                Text(known?.name ?? "New host")
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: PairingTicket.keyFingerprint(parsed.info.daemonId))
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
        } label: {
            Text("Host")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pairing-ticket-host")
    }

    /// Which relay the host will be reached through: the ticket's choice, or this device's
    /// Network setting when that wins.
    private func ticketRelay(_ parsed: PairingTicket) -> some View {
        let relay = (live?.relaySettings ?? RelaySettings()).relay(for: parsed.info.relays)
        return LabeledContent {
            VStack(alignment: .trailing, spacing: 1) {
                Text(relay.name)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if relay.bySetting {
                    Text("Your Network setting")
                        .font(.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
        } label: {
            Text("Relay")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pairing-ticket-relay")
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
            // A code shows its ticket and host to confirm, as a pasted ticket or a link does:
            // anyone can print a QR code.
            Viewfinder(scanning: live != nil && !isBusy, camera: camera) { payload in
                ticket = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                mode = .ticket
            }
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            footer(default: Text(scanFooter))
        }
    }

    private var scanFooter: LocalizedStringKey {
        if !Viewfinder.hasCamera, live != nil {
            return "This device has no camera for scanning. Paste the ticket instead, or open the pairing link on this device."
        }
        if live != nil, camera.isOff {
            return "You can also paste the ticket in the Ticket tab, or open the pairing link on this device."
        }
        return "Point the camera at the code, then check the host and pair. The host shows its code with \(Text(verbatim: "\(Brand.daemonBinary) pair").font(DS.Font.literalSmall))."
    }

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
            .foregroundStyle(DS.Palette.textSecondary)
        } else {
            text.foregroundStyle(DS.Palette.textSecondary)
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
        // A ticket from a link or a scan is there to confirm: the keyboard would cover its host.
        case .ticket: focus = ticket.isEmpty ? .ticket : nil
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

    /// Runs `work`, showing progress only once it has taken longer than the feedback delay.
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
            #if os(macOS)
            // A labelled pop-down, as System Settings draws one.
            LabeledContent("New Key") {
                newKeyMenu {
                    Text("Create or Import…")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
            }
            #else
            newKeyMenu {
                Label("New Key", systemImage: "key.badge.plus")
            }
            #endif
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
                .foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private func newKeyMenu(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Button("Generate Key (ed25519)", systemImage: "key") { run { try flow.generateKey() } }
            Button("Generate Secure Enclave Key", systemImage: "lock.shield") { run { try flow.generateSecureEnclaveKey() } }
            Button("Import Key File…", systemImage: "doc.badge.plus") { importingKey = true }
        } label: {
            label()
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
/// exists and may be used, else a dark square with the brackets and a hint, or the way to turn
/// camera access back on.
private struct Viewfinder: View {
    /// Whether to run the camera (the real hosts model is present and nothing is pairing).
    let scanning: Bool
    let camera: CameraAccess
    let found: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase

    static var hasCamera: Bool {
        #if os(iOS)
        DataScannerViewController.isSupported || CameraAccess.simulated != nil
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(.black)
            #if os(iOS)
            if isLive {
                QRScannerView(found: found)
                    .clipShape(.rect(cornerRadius: DS.Radius.panel))
                    .accessibilityLabel("Camera viewfinder. Point at the QR code shown by the host.")
            }
            #endif
            CornerBrackets()
                .stroke(.white.opacity(isAccessOff ? 0.3 : 0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(48)
                .accessibilityHidden(true)
            #if os(iOS)
            if isAccessOff {
                CameraAccessOffView(restricted: camera.status == .restricted)
            }
            #endif
            if !isLive, !isAccessOff {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.largeTitle.weight(.light))
                    Text(Self.hasCamera || !scanning ? "Point at the QR code shown by the host" : "No camera available")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 72)
                .accessibilityElement(children: .combine)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: scanning) {
            if scanning, Self.hasCamera { await camera.requestIfUndetermined() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { camera.refresh() }
        }
    }

    private var isLive: Bool {
        #if os(iOS)
        scanning && camera.status == .allowed && QRScannerView.isAvailable
        #else
        false
        #endif
    }

    private var isAccessOff: Bool {
        scanning && Self.hasCamera && camera.isOff
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
        SheetScaffold(
            "Import Hosts", subtitle: "From your ssh_config. Choose the ones to add.",
            cancel: SheetAction("Cancel") { hosts.clearSSHConfigAliases() },
            primary: SheetAction("Import \(selected.count)", isEnabled: !selected.isEmpty) {
                hosts.importSSHHosts(Array(selected))
                hosts.clearSSHConfigAliases()
            }
        ) {
            List(hosts.sshConfigAliases, id: \.alias, selection: $selected) { host in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.s) {
                        Text(host.alias).font(DS.Font.rowTitleEmphasis)
                        if Tailscale.isTailnet(host: host.hostName) || Tailscale.isTailnet(host: host.alias) {
                            TailscaleTag()
                        }
                    }
                    Text("\(host.user.map { "\($0)@" } ?? "")\(host.hostName):\(host.port)\(host.proxyJump.isEmpty ? "" : " via \(host.proxyJump.joined(separator: ", "))")")
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
        }
        .onAppear { selected = Set(hosts.sshConfigAliases.map(\.alias)) }
        #if os(macOS)
        .frame(width: 460, height: 420)
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
