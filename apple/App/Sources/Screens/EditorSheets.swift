import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// First use of VS Code on a host: Microsoft's terms, which the user accepts with Microsoft
/// themselves. Nothing of Microsoft's is downloaded or started on the host before Accept; Cancel
/// leaves the host untouched. Asked once per host.
struct EditorLicenceSheet: View {
    let hostName: String
    var accept: () -> Void
    var cancel: () -> Void

    @Environment(\.terminalTheme) private var theme

    private var host: String { hostName.nonEmpty ?? "this host" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(DS.Palette.accent)
                        Text("The editor is Microsoft Visual Studio Code. To open it, \(host) downloads Microsoft’s `code` tool from Microsoft and runs the VS Code Server for you.")
                            .font(DS.Font.rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Both come under Microsoft’s terms. Read them, and accept only if you agree.")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, DS.Space.xs)
                }
                .chromeRows()

                Section {
                    link("Visual Studio Code License", systemImage: "doc.text", url: EditorLicence.vscodeLicenseURL, id: "editor-licence-vscode")
                    link("VS Code Server License", systemImage: "server.rack", url: EditorLicence.serverLicenseURL, id: "editor-licence-server")
                    link("Microsoft Privacy Statement", systemImage: "hand.raised", url: EditorLicence.privacyURL, id: "editor-licence-privacy")
                } header: {
                    SectionTitle("Microsoft’s Terms")
                } footer: {
                    Text("You’re asked once for \(host). No account or sign-in is needed. Not affiliated with or endorsed by Microsoft.")
                }
                .chromeRows()

                Section {
                    Button(action: accept) {
                        HStack {
                            Spacer()
                            Text("Accept and Open VS Code")
                                .font(.body.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.primaryGlass)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("editor-licence-accept")
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .navigationTitle("VS Code on \(host)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .accessibilityIdentifier("editor-licence-cancel")
                }
            }
        }
        .interactiveDismissDisabled()
        #if os(iOS)
        .phoneDetents([.large])
        #else
        .frame(minWidth: 460, idealWidth: 500, minHeight: 500)
        #endif
        .accessibilityIdentifier("editor-licence")
    }

    private func link(_ title: String, systemImage: String, url: URL, id: String) -> some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .accessibilityIdentifier(id)
    }
}

/// The opt-in Remote Tunnel: what it means (Microsoft's relay, the user's own GitHub or
/// Microsoft account on the host), then which account.
struct EditorTunnelOfferSheet: View {
    let hostName: String
    var choose: (EditorTunnelAccount) -> Void
    var cancel: () -> Void

    private var host: String { hostName.nonEmpty ?? "this host" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("vscode.dev reaches \(host) through Microsoft’s Remote Tunnels relay instead of this app’s direct link.")
                            .font(DS.Font.rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The tunnel needs you to sign in on \(host) with your own GitHub or Microsoft account, once. You do that in your browser; this app never sees your password. The usual editor needs no account.")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, DS.Space.xs)
                }
                .chromeRows()

                Section {
                    ForEach(EditorTunnelAccount.allCases, id: \.self) { account in
                        Button {
                            choose(account)
                        } label: {
                            HStack {
                                Label("Continue with \(account.title)", systemImage: account == .github ? "person.crop.circle" : "building.2")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("editor-tunnel-\(account.rawValue)")
                    }
                } header: {
                    SectionTitle("Sign In With")
                } footer: {
                    Text("Microsoft limits tunnels per account and the data they carry each month.")
                }
                .chromeRows()
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .navigationTitle("Open Through a Remote Tunnel")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
            }
        }
        #if os(iOS)
        .phoneDetents([.medium, .large])
        #else
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420)
        #endif
    }
}

/// The tunnel waits for the user to sign in: the code to enter, Copy, and the page to enter it on
/// in the user's own browser. The app never completes the sign-in itself.
struct EditorDeviceCodeSheet: View {
    let login: EditorDeviceCode
    let hostName: String
    var cancel: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    private var page: String {
        let url = login.verificationURL
        return (url.host() ?? url.absoluteString) + (url.path().count > 1 ? url.path() : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: DS.Space.m) {
                        Text(verbatim: login.code)
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .tracking(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Space.m)
                            .accessibilityIdentifier("editor-device-code")
                        Button(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            Self.copy(login.code)
                            withAnimation(DS.Motion.snappy) { copied = true }
                        }
                        .buttonStyle(.glass)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityIdentifier("editor-device-copy")
                    }
                    .padding(.vertical, DS.Space.s)
                } header: {
                    SectionTitle("Your Code")
                } footer: {
                    Text("Enter it at \(page) and sign in with your \(login.account.title) account to let \(hostName.nonEmpty ?? "the host") open a VS Code tunnel.")
                }
                .chromeRows()

                Section {
                    Button {
                        Self.copy(login.code)
                        copied = true
                        openURL(login.verificationURL)
                    } label: {
                        HStack {
                            Spacer()
                            Text("Copy and Open \(page)")
                                .font(.body.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.primaryGlass)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("editor-device-open")
                    HStack(spacing: DS.Space.s) {
                        Spinner(color: DS.Palette.accent, lineWidth: 2)
                            .frame(width: 14, height: 14)
                        Text("Waiting for you to finish signing in…")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .formStyle(.grouped)
            .chromeGrouped()
            .navigationTitle("Sign In to \(login.account.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .accessibilityIdentifier("editor-device-cancel")
                }
            }
        }
        .interactiveDismissDisabled()
        #if os(iOS)
        .phoneDetents([.medium, .large])
        #else
        .frame(minWidth: 440, idealWidth: 480, minHeight: 440)
        #endif
        .accessibilityIdentifier("editor-device-sheet")
    }

    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
