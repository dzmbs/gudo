import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Add a host: type `user@host`, paste a pairing ticket, or scan the host's QR code.
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
    var initialMode: Mode = .ssh

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .ssh
    @State private var destination = ""
    @State private var ticket = ""
    @State private var isPairing = false
    @State private var showsProgress = false
    @State private var error: String?
    @State private var pairedCount = 0
    @FocusState private var focus: Field?

    private enum Field { case destination, ticket }

    init(directory: any HostDirectory, initialMode: Mode = .ssh) {
        self.directory = directory
        self.initialMode = initialMode
        _mode = State(initialValue: Mode.available.contains(initialMode) ? initialMode : .ssh)
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
                case .ssh: sshSection
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
        }
        #if os(iOS)
        .phoneDetents([.medium, .large])
        #else
        .frame(minWidth: 440, idealWidth: 480, minHeight: 360)
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
                preview("User", parsed.user ?? "Your local user name", placeholder: parsed.user == nil)
                preview("Host", parsed.host, placeholder: false)
                preview("Port", parsed.port.map(String.init) ?? "22", placeholder: parsed.port == nil)
            }
        } footer: {
            footer(default: Text("Uses keys from your keychain and ~/.ssh/config. The host key is shown on first connect."))
        }
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
            Viewfinder()
                .frame(maxWidth: 320)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        } footer: {
            footer(default: Text("Pairing starts as soon as the code is in view. The host shows its code with \(Text(verbatim: "\(Brand.name) pair").font(DS.Font.literalSmall))."))
        }
    }

    // MARK: Footer, confirm

    @ViewBuilder
    private func footer(default text: Text) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.error)
        } else if showsProgress {
            HStack(spacing: DS.Space.s) {
                ProgressView().controlSize(.small)
                Text(mode == .ssh ? "Connecting…" : "Pairing…")
            }
        } else {
            text
        }
    }

    private var confirmTitle: String { mode == .ssh ? "Connect" : "Pair" }

    private var canConfirm: Bool {
        guard !isPairing else { return false }
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
            directory.quickConnect(destination.trimmingCharacters(in: .whitespaces))
            pairedCount += 1
            dismiss()
        case .ticket:
            isPairing = true
            Task {
                let progress = Task {
                    try await Task.sleep(for: DS.Motion.feedbackDelay)
                    showsProgress = true
                }
                defer {
                    progress.cancel()
                    showsProgress = false
                    isPairing = false
                }
                do {
                    _ = try await directory.pair(ticket: ticket)
                    pairedCount += 1
                    dismiss()
                } catch {
                    self.error = "Couldn't pair: \(error.localizedDescription)"
                }
            }
        case .scan:
            break
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

/// A camera viewfinder stand-in: a dark square with corner brackets around the scan area.
private struct Viewfinder: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .fill(.black)
            CornerBrackets()
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(48)
            VStack(spacing: DS.Space.s) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 36, weight: .light))
                Text("Point at the QR code shown by the host")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 72)
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
