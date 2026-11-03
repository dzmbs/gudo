import CryptoKit
import DesignSystem
import GudoCore
import HostKit
import SwiftUI

/// Settings › SSH Keys: the app's keys (Secure Enclave and Keychain) and, on the Mac, the key
/// pairs in `~/.ssh` and the SSH agent's keys, used where they are. Create, import, and for
/// every key its public half, fingerprint and "Add to Server".
struct SSHKeysView: View {
    let hosts: HostsModel
    @State private var creating = false
    @State private var importing = false
    @State private var importFailure: String?

    private var inventory: SSHInventory { hosts.sshInventory }

    var body: some View {
        Form {
            Section {
                if hosts.keys.keys.isEmpty {
                    Text("No keys yet")
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                ForEach(hosts.keys.keys) { key in
                    NavigationLink {
                        SSHKeyDetailView(hosts: hosts, key: .app(key))
                    } label: {
                        KeyRow(title: key.label, type: key.typeName, fingerprint: key.fingerprint,
                               systemImage: key.kind == .secureEnclave ? "lock.shield" : "key")
                    }
                    .accessibilityIdentifier("ssh-key-\(key.label)")
                }
                Button("Create Key…", systemImage: "plus") { creating = true }
                    .accessibilityIdentifier("keys-create")
                Button("Import Key…", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("keys-import")
            } header: {
                SectionTitle(inventory.isDesktop ? "Keychain" : "Keys")
            } footer: {
                Text("Kept in this device's Keychain or Secure Enclave, never synced. Secure Enclave keys can't be copied off the device.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            if inventory.isDesktop {
                Section {
                    if inventory.localKeys.isEmpty {
                        Text("No key pairs").foregroundStyle(DS.Palette.textTertiary)
                    }
                    ForEach(inventory.localKeys, id: \.path) { key in
                        NavigationLink {
                            SSHKeyDetailView(hosts: hosts, key: .file(key))
                        } label: {
                            KeyRow(title: URL(fileURLWithPath: key.path).lastPathComponent,
                                   type: SSHKeyText.typeName(key.info.algorithm) + (key.encrypted ? " · passphrase" : ""),
                                   fingerprint: key.info.fingerprint, systemImage: "doc")
                        }
                    }
                } header: {
                    SectionTitle("In ~/.ssh")
                } footer: {
                    Text("Used where they are. Private keys never leave ~/.ssh.")
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Section {
                    if inventory.agentKeys.isEmpty {
                        Text("No keys in the agent").foregroundStyle(DS.Palette.textTertiary)
                    }
                    ForEach(inventory.agentKeys, id: \.fingerprint) { key in
                        NavigationLink {
                            SSHKeyDetailView(hosts: hosts, key: .agent(key))
                        } label: {
                            KeyRow(title: key.comment.isEmpty ? "Agent key" : key.comment,
                                   type: SSHKeyText.typeName(key.algorithm), fingerprint: key.fingerprint, systemImage: "person.badge.key")
                        }
                    }
                } header: {
                    SectionTitle("SSH Agent")
                } footer: {
                    Text("Keys your Mac's SSH agent holds, from ssh-add, the Keychain, 1Password or Secretive.")
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .formStyle(.grouped)
        .chromeGrouped()
        .navigationTitle("SSH Keys")
        .task { await inventory.refresh() }
        .sheet(isPresented: $creating) {
            CreateSSHKeySheet(keys: hosts.keys, suggestedName: "") { _ in }
        }
        .modifier(KeyImporter(isPresented: $importing, keys: hosts.keys, failure: $importFailure) { _ in })
    }
}

/// Settings' row into SSH Keys.
struct SSHKeysSettingsSection: View {
    private let keys = AppModel.shared.hosts.keys

    var body: some View {
        Section {
            NavigationLink(value: SettingsPage.sshKeys) {
                LabeledContent("SSH Keys") {
                    Text(keys.keys.isEmpty ? "None" : "\(keys.keys.count)")
                        .monospacedDigit()
                }
            }
            .accessibilityIdentifier("settings-ssh-keys")
            .settingAnchor("ssh-keys")
        } header: {
            Text("SSH")
        } footer: {
            Text("Keys for signing in to servers: create, import, and add them to a server.")
        }
    }
}

private struct KeyRow: View {
    let title: String
    let type: String
    let fingerprint: String
    let systemImage: String

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text("\(type) · \(SSHKeyRowText.shortFingerprint(fingerprint))")
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

enum SSHKeyRowText {
    /// `SHA256:abcd…wxyz`.
    static func shortFingerprint(_ fingerprint: String) -> String {
        let body = fingerprint.hasPrefix("SHA256:") ? String(fingerprint.dropFirst(7)) : fingerprint
        guard body.count > 16 else { return fingerprint }
        return "SHA256:\(body.prefix(8))…\(body.suffix(6))"
    }
}

/// One key: its public half (Copy, Share), fingerprint, and "Add to Server".
struct SSHKeyDetailView: View {
    enum Key {
        case app(SSHKey)
        case file(SshLocalKey)
        case agent(SshPublicKeyInfo)
    }

    let hosts: HostsModel
    let key: Key
    @Environment(\.dismiss) private var dismiss
    @State private var target: HostRecord?
    @State private var result: String?
    @State private var failure: String?
    @State private var confirmingDelete = false
    @State private var label = ""

    var body: some View {
        Form {
            Section {
                if case .app = key {
                    LabeledContent("Name") {
                        TextField("Name", text: $label)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .onSubmit(rename)
                    }
                }
                LabeledContent("Type", value: typeName)
                LabeledContent("Fingerprint") {
                    Text(fingerprint)
                        .font(DS.Font.literalSmall)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                if case .file(let file) = key {
                    LabeledContent("File") {
                        Text(file.path.replacingOccurrences(of: HostsModel.homeDirectory, with: "~"))
                            .font(DS.Font.literalSmall)
                            .textSelection(.enabled)
                    }
                }
            }
            Section {
                Text(publicKey)
                    .font(DS.Font.literalSmall)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .accessibilityIdentifier("key-public")
                Button("Copy Public Key", systemImage: "doc.on.doc") { copy(publicKey) }
                ShareLink(item: publicKey, preview: SharePreview("\(title).pub")) {
                    Label("Share Public Key", systemImage: "square.and.arrow.up")
                }
            } header: {
                SectionTitle("Public Key")
            }
            Section {
                let candidates = hosts.authorizableHosts
                Menu {
                    ForEach(candidates) { record in
                        Button(record.ssh?.display ?? record.name) { target = record }
                    }
                } label: {
                    Label("Add to Server…", systemImage: "server.rack")
                }
                .disabled(candidates.isEmpty)
                .accessibilityIdentifier("key-add-to-server")
                if let result {
                    Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.done)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.error)
                }
            } footer: {
                Text(hosts.authorizableHosts.isEmpty
                    ? "Connect to a server over SSH first; the key is added to its ~/.ssh/authorized_keys over that session."
                    : "Adds the key to the server's ~/.ssh/authorized_keys over its open session, as ssh-copy-id does.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            if case .app = key {
                Section {
                    Button("Delete Key", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .chromeGrouped()
        .navigationTitle(title)
        .onAppear { if case .app(let appKey) = key { label = appKey.label } }
        .confirmationDialog(
            "Add this key to \(target?.ssh?.display ?? "the server")?",
            isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible
        ) {
            Button("Add Key") { if let target { add(to: target) } }
        } message: {
            Text("Anyone holding this key will be able to sign in as \(target?.ssh?.user ?? "this user").")
        }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("Hosts that sign in with it will ask for another way in. Servers keep it in authorized_keys until you remove it there.")
        }
    }

    private var title: String {
        switch key {
        case .app(let key): key.label
        case .file(let file): URL(fileURLWithPath: file.path).lastPathComponent
        case .agent(let info): info.comment.isEmpty ? "Agent Key" : info.comment
        }
    }

    private var typeName: String {
        switch key {
        case .app(let key): key.typeName
        case .file(let file): SSHKeyText.typeName(file.info.algorithm)
        case .agent(let info): SSHKeyText.typeName(info.algorithm)
        }
    }

    private var fingerprint: String {
        switch key {
        case .app(let key): key.fingerprint
        case .file(let file): file.info.fingerprint
        case .agent(let info): info.fingerprint
        }
    }

    private var publicKey: String {
        switch key {
        case .app(let key): key.publicKey
        case .file(let file): file.info.publicKey
        case .agent(let info): info.publicKey
        }
    }

    private func add(to record: HostRecord) {
        result = nil
        failure = nil
        Task {
            do {
                try await hosts.authorize(publicKey, onHost: record.id)
                result = "Added to \(record.ssh?.display ?? record.name)"
            } catch {
                failure = SshErrorText.describe(error)
            }
        }
    }

    private func rename() {
        guard case .app(let appKey) = key else { return }
        try? hosts.keys.rename(appKey.id, to: label.trimmingCharacters(in: .whitespaces))
    }

    private func delete() {
        guard case .app(let appKey) = key else { return }
        try? hosts.keys.remove(appKey.id)
        dismiss()
    }
}

/// Creates a key: Secure Enclave (recommended), Ed25519, or RSA 4096 for old servers, with an
/// optional passphrase for software keys.
struct CreateSSHKeySheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case secureEnclave, ed25519, rsa
        var id: String { rawValue }

        var title: String {
            switch self {
            case .secureEnclave: "Secure Enclave"
            case .ed25519: "Ed25519"
            case .rsa: "RSA 4096"
            }
        }
    }

    let keys: KeyStore
    let suggestedName: String
    let created: (SSHKey) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = SecureEnclave.isAvailable ? .secureEnclave : .ed25519
    @State private var name = ""
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var rememberPassphrase = true
    @State private var isBusy = false
    @State private var failure: String?

    var body: some View {
        ThemedRoot {
            SheetScaffold(
                "Create Key",
                cancel: SheetAction("Cancel") { dismiss() },
                primary: SheetAction("Create", isEnabled: canCreate, isBusy: isBusy, busyTitle: "Creating…", identifier: "key-create-confirm", action: create)
            ) {
                Form {
                    Section {
                        LabeledContent("Name") {
                            TextField("Name", text: $name, prompt: Text(defaultName))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                        Picker("Type", selection: $kind) {
                            ForEach(Kind.allCases.filter { $0 != .secureEnclave || SecureEnclave.isAvailable }) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .accessibilityIdentifier("key-type")
                    } footer: {
                        Text(kindFooter).foregroundStyle(DS.Palette.textSecondary)
                    }
                    if kind != .secureEnclave {
                        Section {
                            SecureField("Passphrase", text: $passphrase, prompt: Text("Optional"))
                            if !passphrase.isEmpty {
                                SecureField("Confirm", text: $confirmation, prompt: Text("Confirm passphrase"))
                                Toggle("Remember Passphrase", isOn: $rememberPassphrase)
                            }
                        } footer: {
                            Text(passphrase.isEmpty
                                ? "Without a passphrase the key is protected by this device's Keychain."
                                : "Without Remember, the passphrase is asked for each time a host signs in with this key.")
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    if let failure {
                        Section {
                            Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.error)
                        }
                    }
                }
                .formStyle(.grouped)
                .chromeGrouped()
            }
            #if os(macOS)
            .frame(width: 440, height: 380)
            #endif
        }
        .chromeSheetBackground()
    }

    private var defaultName: String {
        suggestedName.isEmpty ? "\(Brand.name) key" : suggestedName
    }

    private var kindFooter: String {
        switch kind {
        case .secureEnclave: "Recommended. Created inside this device's Secure Enclave: it can't be copied or exported. ECDSA P-256."
        case .ed25519: "Modern and widely supported. Stored in this device's Keychain."
        case .rsa: "Only for servers that accept nothing newer."
        }
    }

    private var canCreate: Bool {
        !isBusy && (passphrase.isEmpty || passphrase == confirmation)
    }

    private func create() {
        let label = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name.trimmingCharacters(in: .whitespaces)
        isBusy = true
        failure = nil
        let kind = kind
        let passphrase = passphrase
        let remember = rememberPassphrase
        Task {
            // RSA takes seconds: let the button show its spinner first.
            await Task.yield()
            do {
                let key: SSHKey = switch kind {
                case .secureEnclave: try keys.generateSecureEnclaveKey(label: label)
                case .ed25519: try keys.generate(label: label, type: .ed25519, passphrase: passphrase, rememberPassphrase: remember)
                case .rsa: try keys.generate(label: label, type: .rsa4096, passphrase: passphrase, rememberPassphrase: remember)
                }
                created(key)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            isBusy = false
        }
    }
}
