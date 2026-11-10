import DesignSystem
import GudoCore
import HostKit
import SwiftUI
import UniformTypeIdentifiers

/// The SSH host form's sections, shared by Add Host and Edit Host: the address with its
/// suggestions, User, Port, Jump Host and Name, how to sign in, and Test Connection.
struct SSHHostFormSections: View {
    @Bindable var flow: JustSSHFlow
    let submit: () -> Void

    @FocusState private var focus: Field?
    @State private var creatingKey = false
    @State private var importingKey = false
    @State private var importFailure: String?

    enum Field: Hashable { case address, user, port, jump, name, password, passphrase }

    var body: some View {
        addressSection
        SSHSignInSection(flow: flow, focus: $focus, creatingKey: $creatingKey, importingKey: $importingKey, submit: submit)
        if let key = flow.newKey { NewKeySection(flow: flow, key: key) }
        testSection
            .sheet(isPresented: $creatingKey) {
                CreateSSHKeySheet(keys: flow.hosts.keys, suggestedName: "") { key in
                    flow.select(key)
                }
            }
            .modifier(KeyImporter(isPresented: $importingKey, keys: flow.hosts.keys, failure: $importFailure) { key in
                flow.select(key)
            })
            .task { await flow.refreshInventory() }
            .onAppear { if flow.editingHostId == nil { focus = .address } }
            .onChange(of: focus) { old, _ in if old == .address { flow.tidyDestination() } }
    }

    // MARK: Address

    @ViewBuilder private var addressSection: some View {
        Section {
            TextField("Address", text: $flow.destination, prompt: Text(addressPrompt))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(DS.Font.literal)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .submitLabel(.next)
                .focused($focus, equals: .address)
                .onSubmit {
                    flow.tidyDestination()
                    focus = flow.user.isEmpty ? .user : nil
                }
                .accessibilityIdentifier("pairing-destination")
            if focus == .address {
                ForEach(flow.suggestions()) { suggestion in
                    SuggestionRow(suggestion: suggestion) {
                        flow.choose(suggestion)
                        focus = flow.user.isEmpty ? .user : nil
                    }
                }
            }
            if let alias = flow.alias {
                LabeledContent {
                    Text(flow.aliasHostName.map { $0 == alias ? "" : $0 } ?? "")
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Label(flow.inventory.isDesktop ? "From ~/.ssh/config" : "From your ssh_config", systemImage: "doc.text")
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .accessibilityIdentifier("ssh-from-config")
            }
            FormTextRow("User", text: $flow.user, prompt: "Required", field: .user, focus: $focus)
                .accessibilityIdentifier("ssh-user")
            FormTextRow("Port", text: $flow.port, prompt: "22", field: .port, focus: $focus, numeric: true)
                .accessibilityIdentifier("ssh-port")
            FormTextRow("Jump Host", text: $flow.proxyJump, prompt: "None", field: .jump, focus: $focus)
                .accessibilityIdentifier("ssh-jump")
            FormTextRow("Name", text: $flow.name, prompt: flow.alias ?? flow.typedHost ?? "Optional", field: .name, focus: $focus, literal: false)
                .accessibilityIdentifier("ssh-name")
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
            Text(addressFooter)
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private var addressPrompt: String {
        flow.inventory.configHosts.isEmpty ? "Host, user@host:port or ssh command" : "Host, ssh_config alias or ssh command"
    }

    private var addressFooter: String {
        "Paste an ssh command to fill the fields. Jump Host takes ProxyJump hops, like admin@bastion."
    }

    private var isTailnet: Bool {
        guard let host = flow.typedHost else { return false }
        return Tailscale.isTailnet(host: host) || flow.aliasHostName.map { Tailscale.isTailnet(host: $0) } == true
    }

    // MARK: Test

    private var testSection: some View {
        Section {
            Button {
                Task { await flow.runTest() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    testStatus
                }
                .contentShape(.rect)
            }
            .disabled((try? flow.endpoint()) == nil || flow.test == .running)
            .accessibilityIdentifier("ssh-test")
        } footer: {
            if case .failed(let reason) = flow.test {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Palette.error)
                    .accessibilityIdentifier("ssh-test-error")
            }
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch flow.test {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded(let elapsed):
            Label("Signed in, \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DS.Palette.done)
                .font(DS.Font.rowSubtitle)
                .accessibilityIdentifier("ssh-test-ok")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(DS.Palette.error)
        case nil:
            EmptyView()
        }
    }
}

/// A labelled text field in a form row: the label leading, the value trailing (as Settings
/// draws editable rows).
private struct FormTextRow: View {
    let label: String
    @Binding var text: String
    let prompt: String
    let field: SSHHostFormSections.Field
    var focus: FocusState<SSHHostFormSections.Field?>.Binding
    var numeric = false
    var literal = true

    init(
        _ label: String, text: Binding<String>, prompt: String, field: SSHHostFormSections.Field,
        focus: FocusState<SSHHostFormSections.Field?>.Binding, numeric: Bool = false, literal: Bool = true
    ) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.field = field
        self.focus = focus
        self.numeric = numeric
        self.literal = literal
    }

    var body: some View {
        LabeledContent {
            TextField(label, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .font(literal ? DS.Font.literal : nil)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(numeric ? .numberPad : .asciiCapable)
                #endif
                .focused(focus, equals: field)
        } label: {
            Text(label)
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: JustSSHFlow.Suggestion
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: icon)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.value)
                        .font(DS.Font.literal)
                        .foregroundStyle(DS.Palette.text)
                    if let detail = suggestion.detail, detail != suggestion.value {
                        Text(detail)
                            .font(DS.Font.literalSmall)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(source)
                    .font(DS.Font.badge)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ssh-suggestion-\(suggestion.value)")
    }

    private var icon: String {
        switch suggestion.source {
        case .sshConfig: "doc.text"
        case .saved: "clock"
        case .knownHosts: "checkmark.shield"
        }
    }

    private var source: String {
        switch suggestion.source {
        case .sshConfig: "ssh_config"
        case .saved: "Saved"
        case .knownHosts: "known_hosts"
        }
    }
}

/// "Sign In With": the agent's keys, key pairs in `~/.ssh`, the app's keys, or a password,
/// with Create and Import.
private struct SSHSignInSection: View {
    @Bindable var flow: JustSSHFlow
    var focus: FocusState<SSHHostFormSections.Field?>.Binding
    @Binding var creatingKey: Bool
    @Binding var importingKey: Bool
    let submit: () -> Void

    private var inventory: SSHInventory { flow.inventory }

    var body: some View {
        Section {
            Picker("Sign In With", selection: $flow.auth) {
                if inventory.isDesktop, !inventory.agentKeys.isEmpty {
                    Section("SSH Agent") {
                        Text("Any Agent Key").tag(JustSSHFlow.AuthChoice.agent)
                        ForEach(inventory.agentKeys, id: \.fingerprint) { key in
                            Text(SSHKeyText.agentTitle(key)).tag(JustSSHFlow.AuthChoice.agentKey(fingerprint: key.fingerprint))
                        }
                    }
                }
                if inventory.isDesktop, !inventory.localKeys.isEmpty {
                    Section("In ~/.ssh") {
                        ForEach(inventory.localKeys, id: \.path) { key in
                            Text(URL(fileURLWithPath: key.path).lastPathComponent).tag(JustSSHFlow.AuthChoice.keyFile(path: key.path))
                        }
                    }
                }
                if case .keyFile(let path) = flow.auth, inventory.localKey(at: path) == nil {
                    Text(URL(fileURLWithPath: path).lastPathComponent).tag(flow.auth)
                }
                if !flow.hosts.keys.keys.isEmpty {
                    Section(inventory.isDesktop ? "Keychain" : "Keys") {
                        ForEach(flow.hosts.keys.keys) { key in
                            Text(key.label).tag(JustSSHFlow.AuthChoice.key(id: key.id))
                        }
                    }
                }
                Divider()
                Text("Password").tag(JustSSHFlow.AuthChoice.password)
            }
            .accessibilityIdentifier("ssh-sign-in")
            if let detail = selectionDetail {
                LabeledContent("Key") {
                    Text(detail)
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            switch flow.auth {
            case .password:
                SecureField("Password", text: $flow.password)
                    .focused(focus, equals: .password)
                    .onSubmit(submit)
                    .accessibilityIdentifier("ssh-password")
                Toggle("Remember Password", isOn: $flow.rememberPassword)
            default:
                if flow.needsPassphrase {
                    SecureField("Passphrase", text: $flow.passphrase)
                        .focused(focus, equals: .passphrase)
                        .onSubmit(submit)
                        .accessibilityIdentifier("ssh-passphrase")
                    Toggle("Remember Passphrase", isOn: $flow.rememberPassphrase)
                }
            }
            HStack(spacing: DS.Space.m) {
                Button("Create Key…", systemImage: "key") { creatingKey = true }
                    .accessibilityIdentifier("ssh-create-key")
                Button("Import Key…", systemImage: "square.and.arrow.down") { importingKey = true }
                    .accessibilityIdentifier("ssh-import-key")
            }
            .buttonStyle(.borderless)
        } header: {
            SectionTitle("Sign In")
        } footer: {
            if let footer {
                Text(footer).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private var selectionDetail: String? {
        switch flow.auth {
        case .password, .agent: nil
        case .agentKey(let fingerprint):
            inventory.agentKeys.first { $0.fingerprint == fingerprint }.map {
                "\(SSHKeyText.typeName($0.algorithm)) · \(SSHKeyRowText.shortFingerprint($0.fingerprint))"
            }
        case .keyFile(let path):
            inventory.localKey(at: path).map { key in
                [SSHKeyText.typeName(key.info.algorithm), key.info.comment, key.encrypted ? "passphrase" : nil]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            } ?? path
        case .key(let id):
            flow.hosts.keys.key(id).map { "\($0.typeName) · \(SSHKeyRowText.shortFingerprint($0.fingerprint))" }
        }
    }

    private var footer: String? {
        switch flow.auth {
        case .agent, .agentKey:
            "Keys your Mac's SSH agent holds, from ssh-add, the Keychain, 1Password or Secretive."
        case .keyFile:
            "Used where it is. The private key never leaves ~/.ssh."
        case .key(let id):
            flow.hosts.keys.key(id)?.kind == .secureEnclave
                ? "Lives in this device's Secure Enclave and can't be copied."
                : "Stored in this device's Keychain."
        case .password:
            flow.editingHostId == nil ? nil : "Leave empty to keep the saved password."
        }
    }
}

/// The public half of a key just made or imported, to put on the server.
private struct NewKeySection: View {
    let flow: JustSSHFlow
    let key: SSHKey

    var body: some View {
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
            SectionTitle("Public Key")
        } footer: {
            Text("Add it to ~/.ssh/authorized_keys on the host, or sign in once with a password and add it from Settings › SSH Keys.")
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

/// Short text for keys in pickers and lists.
enum SSHKeyText {
    static func typeName(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "Ed25519"
        case "ssh-rsa": "RSA"
        case "ecdsa-sha2-nistp256": "ECDSA P-256"
        case "ecdsa-sha2-nistp384": "ECDSA P-384"
        case "ecdsa-sha2-nistp521": "ECDSA P-521"
        case "sk-ssh-ed25519@openssh.com": "Ed25519 Security Key"
        case "sk-ecdsa-sha2-nistp256@openssh.com": "ECDSA Security Key"
        default: algorithm
        }
    }

    static func agentTitle(_ key: SshPublicKeyInfo) -> String {
        let comment = key.comment.trimmingCharacters(in: .whitespaces)
        let name = comment.isEmpty ? String(key.fingerprint.dropFirst(7).prefix(12)) : comment
        return "\(name) (\(typeName(key.algorithm)))"
    }
}

/// The host-key step, as a sheet over the form: a new host's key to check, or a changed key
/// that blocks until the user decides.
struct HostKeyTrustModifier: ViewModifier {
    let prompts: HostKeyPrompts

    func body(content: Content) -> some View {
        content
            .onAppear { prompts.presenters += 1 }
            .onDisappear { prompts.presenters -= 1 }
            .sheet(item: Binding(get: { prompts.pending }, set: { if $0 == nil, prompts.pending != nil { prompts.answer(false) } })) { prompt in
                HostKeyTrustSheet(prompt: prompt) { prompts.answer($0) }
                    .interactiveDismissDisabled()
            }
    }
}

private struct HostKeyTrustSheet: View {
    let prompt: HostKeyPrompts.Prompt
    let answer: (Bool) -> Void

    var body: some View {
        ThemedRoot {
            SheetScaffold(
                prompt.isChange ? "Host Key Changed" : "Trust This Host?",
                cancel: SheetAction("Cancel", identifier: "host-key-cancel") { answer(false) },
                primary: prompt.isChange ? nil : SheetAction("Trust and Connect", identifier: "trust-host") { answer(true) }
            ) {
                Form {
                    Section {
                        if prompt.isChange {
                            Label {
                                Text("The key for \(prompt.host) is different from the one saved. The server may have been reinstalled, or someone may be intercepting the connection.")
                            } icon: {
                                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(DS.Palette.error)
                            }
                        } else {
                            Text("First connection to \(prompt.host). Check that this fingerprint matches the server's before you trust it.")
                        }
                    }
                    Section {
                        LabeledContent("Key Type", value: SSHKeyText.typeName(prompt.algorithm))
                        if let expected = prompt.expected {
                            fingerprint("Saved", expected.joined(separator: "\n"))
                            fingerprint("Now", prompt.fingerprint, highlighted: true)
                        } else {
                            fingerprint("Fingerprint", prompt.fingerprint)
                        }
                    } footer: {
                        Text(prompt.isChange
                            ? "Replace the saved key only if you know why it changed."
                            : "On the server, ssh-keygen -lf /etc/ssh/ssh_host_\(keyFileName)_key.pub prints it.")
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    if prompt.isChange {
                        Section {
                            Button("Replace Saved Key", role: .destructive) { answer(true) }
                                .accessibilityIdentifier("host-key-replace")
                        }
                    }
                }
                .formStyle(.grouped)
                .chromeGrouped()
            }
            #if os(macOS)
            .frame(width: 460, height: prompt.isChange ? 380 : 320)
            #endif
        }
        .chromeSheetBackground()
    }

    private var keyFileName: String {
        switch prompt.algorithm {
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": "rsa"
        case let algorithm where algorithm.hasPrefix("ecdsa"): "ecdsa"
        default: "ed25519"
        }
    }

    private func fingerprint(_ label: String, _ value: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.rowSubtitle)
                .foregroundStyle(DS.Palette.textSecondary)
            Text(value)
                .font(DS.Font.literal)
                .foregroundStyle(highlighted ? DS.Palette.error : DS.Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hosts › host › Edit: the same form for a saved SSH host.
struct EditSSHHostSheet: View {
    @State private var flow: JustSSHFlow
    @Environment(\.dismiss) private var dismiss

    init(hosts: HostsModel, record: HostRecord) {
        _flow = State(initialValue: JustSSHFlow(hosts: hosts, editing: record))
    }

    var body: some View {
        ThemedRoot {
            SheetScaffold(
                "Edit Host",
                cancel: SheetAction("Cancel") { dismiss() },
                primary: SheetAction("Save", isEnabled: (try? flow.endpoint()) != nil, identifier: "ssh-save", action: save)
            ) {
                Form {
                    SSHHostFormSections(flow: flow, submit: save).chromeRows()
                    if case .failed(let reason) = flow.step {
                        Section {
                        } footer: {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(DS.Palette.error)
                        }
                    }
                }
                .formStyle(.grouped)
                .chromeGrouped()
                .modifier(HostKeyTrustModifier(prompts: flow.hosts.hostKeyPrompts))
            }
            #if os(iOS)
            .phoneDetents([.large])
            #else
            .frame(width: 500, height: 600)
            #endif
        }
        .chromeSheetBackground()
    }

    private func save() {
        Task {
            await flow.connect()
            if case .connected = flow.step { dismiss() }
        }
    }
}

/// Picks a private key file (or a paste on iOS), asks for its passphrase when it has one,
/// and adds it to the app's keys.
struct KeyImporter: ViewModifier {
    @Binding var isPresented: Bool
    let keys: KeyStore
    @Binding var failure: String?
    let imported: (SSHKey) -> Void

    @State private var pending: (pem: Data, label: String)?
    @State private var passphrase = ""

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.data, .plainText, .item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let pem = try? Data(contentsOf: url) else { return }
                add(pem: pem, label: url.lastPathComponent)
            }
            .alert("Key Passphrase", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                SecureField("Passphrase", text: $passphrase)
                Button("Import") {
                    if let pending { add(pem: pending.pem, label: pending.label, passphrase: passphrase) }
                    passphrase = ""
                }
                Button("Cancel", role: .cancel) { passphrase = "" }
            } message: {
                Text("\(pending?.label ?? "This key") is protected by a passphrase.")
            }
            .alert("Couldn't Import the Key", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func add(pem: Data, label: String, passphrase: String? = nil) {
        if passphrase == nil, privateKeyIsEncrypted(pem: pem) {
            pending = (pem, label)
            return
        }
        pending = nil
        Task {
            do {
                imported(try await keys.importKey(pem: pem, passphrase: passphrase, label: label))
            } catch {
                failure = SshErrorText.describe(error)
            }
        }
    }
}
