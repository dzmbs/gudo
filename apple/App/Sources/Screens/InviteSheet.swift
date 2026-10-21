import CoreImage
import CoreImage.CIFilterBuiltins
import DesignSystem
import HostKit
import PaneLayout
import SwiftUI
import UnnamedCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Share Session: who is here and where, an invite (roles, scope, expiry, uses → link + QR +
/// share sheet), and for the owner the grants and the audit log. A guest sees their own access
/// instead. Everything reads the window host's `MultiplayerSession`.
struct InviteSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    /// `-shareRoute grants|audit` opens straight there (screenshots).
    @State private var path: [ShareRoute] = UserDefaults.standard.string(forKey: "shareRoute").flatMap(ShareRoute.init(rawValue:)).map { [$0] } ?? []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let session = workspace.multiplayer {
                    ShareRoot(workspace: workspace, session: session)
                        .navigationDestination(for: ShareRoute.self) { route in
                            switch route {
                            case .grants: GrantsView(session: session)
                            case .audit: AuditLogView(session: session)
                            }
                        }
                } else {
                    EmptyState(
                        "Sharing Needs the Helper", systemImage: "person.2.slash",
                        message: "Only hosts running the helper can be shared. This device's own shell and plain SSH hosts stay private.") {
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Share Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("share-done")
                }
            }
        }
        #if os(iOS)
        .phoneDetents([.large])
        // People, the invite and its QR code side by side need the room of a page sheet.
        .presentationSizing(.page)
        #else
        .frame(minWidth: 520, idealWidth: 560, minHeight: 620, idealHeight: 720)
        #endif
    }
}

enum ShareRoute: String, Hashable {
    case grants, audit
}

private struct ShareRoot: View {
    let workspace: Workspace
    let session: MultiplayerSession

    @State private var draft = InviteDraft()
    @State private var created: CreatedInvite?
    @State private var createdSummary = ""
    @State private var isCreating = false
    @State private var error: String?
    @State private var revoking: UnnamedCore.Participant?

    var body: some View {
        Form {
            header.chromeRows()
            if session.isOwner, !session.knocks.isEmpty {
                waiting.chromeRows()
            }
            people.chromeRows()
            if session.isOwner {
                if let created {
                    InviteResult(invite: created, summary: createdSummary) {
                        withAnimation(DS.Motion.panel) { self.created = nil }
                    }
                    .chromeRows()
                } else {
                    composer.chromeRows()
                }
            } else {
                yourAccess.chromeRows()
            }
            if session.isOwner {
                ApprovalRulesSection(session: session, sessionId: sessionId, supported: supportsMP2)
                    .chromeRows()
                Section {
                    NavigationLink(value: ShareRoute.grants) {
                        Label { rowText("Access & Grants", "Links, devices, revoke") } icon: { Image(systemName: "key") }
                    }
                    .accessibilityIdentifier("open-grants")
                    NavigationLink(value: ShareRoute.audit) {
                        Label { rowText("Audit Log", "Joins, approvals with signer, revocations") } icon: { Image(systemName: "list.bullet.rectangle.portrait") }
                    }
                    .accessibilityIdentifier("open-audit")
                }
                .chromeRows()
            }
        }
        .formStyle(.grouped)
        .chromeGrouped()
        .confirmationDialog(
            "Remove \(revoking?.name ?? "")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible, presenting: revoking
        ) { person in
            Button("Revoke Access", role: .destructive) {
                Task { await revoke(person) }
            }
        } message: { person in
            Text("\(person.name) is disconnected at once and their link stops working. Anything they already started keeps running.")
        }
    }

    /// The host speaks MP2: knock links, scrollback since joining, approval rules.
    private var supportsMP2: Bool {
        LaunchOptions.mock || workspace.daemon?.daemonInfo?.multiplayer2 == true
    }

    private var sessionId: UInt64? {
        workspace.daemon?.layout.sessionId ?? (LaunchOptions.mock ? 1 : nil)
    }

    // MARK: Knocks

    private var waiting: some View {
        Section {
            ForEach(session.knocks, id: \.knockId) { knock in
                KnockRow(knock: knock, session: session)
            }
        } header: {
            SectionTitle("Asking to Join", count: session.knocks.count)
        } footer: {
            Text("They only see the session once you let them in. Earlier output stays hidden unless you choose otherwise.")
        }
    }

    private func rowText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(DS.Font.rowTitle)
            Text(subtitle).font(DS.Font.rowSubtitle).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.session.activeTab.map(workspace.title(of:)) ?? "Session")
                        .font(DS.Font.title)
                        .lineLimit(1)
                    Text(headerSubtitle)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                PresenceStack(session.others.map(\.avatar), limit: 4)
            }
            .padding(.vertical, 2)
        }
    }

    private var headerSubtitle: String {
        let count = session.others.count
        let who = count == 0 ? "Only you" : count == 1 ? "You and 1 other" : "You and \(count) others"
        return "\(who) · \(session.isOwner ? "you own this host" : roleWords(session.roles))"
    }

    // MARK: Invite composer

    private var composer: some View {
        Section {
            TextField("Name, shown to everyone", text: $draft.name)
                .textContentType(.name)
                .accessibilityIdentifier("invite-name")
            RolePicker(roles: $draft.roles)
                .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.m, bottom: DS.Space.s, trailing: DS.Space.m))
            VStack(alignment: .leading, spacing: DS.Space.row) {
                Picker("Scope", selection: $draft.scope) {
                    ForEach(InviteDraft.ScopeChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("invite-scope")
                Text(draft.scope.detail)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .contentTransition(.opacity)
            }
            .padding(.vertical, 2)
            Picker("Expires", selection: $draft.expiry) {
                ForEach(InviteDraft.Expiry.allCases) { Text($0.title).tag($0) }
            }
            Picker("Who Can Use It", selection: $draft.uses) {
                ForEach(InviteDraft.Uses.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Can Invite Others", isOn: $draft.delegate)
            if supportsMP2 {
                Toggle(isOn: $draft.knock) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Ask Me First")
                        Text("Whoever opens the link knocks; you let them in.")
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .accessibilityIdentifier("invite-knock")
                Picker("Earlier Output", selection: $draft.sinceJoin) {
                    Text("Hidden").tag(true)
                    Text("Visible").tag(false)
                }
                .accessibilityIdentifier("invite-history")
            }
            Button(action: create) {
                HStack {
                    Spacer()
                    if isCreating {
                        Text("Signing invite…")
                    } else {
                        Label("Create Invite Link", systemImage: "link.badge.plus")
                    }
                    Spacer()
                }
                .font(.body.weight(.semibold))
                .padding(.vertical, 4)
            }
            .buttonStyle(.primaryGlass)
            .disabled(isCreating)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DS.Space.s, leading: 0, bottom: 0, trailing: 0))
            .accessibilityIdentifier("create-invite")
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.error)
            }
        } header: {
            SectionTitle("Invite")
        } footer: {
            Text(composerFooter)
        }
        .onAppear {
            // Older helpers take neither knock links nor history limits.
            if !supportsMP2 {
                draft.knock = false
                draft.sinceJoin = false
            }
        }
    }

    private var composerFooter: String {
        let history = draft.sinceJoin ? "They see output from when they join, not what came before. " : ""
        return history + "Signed by this device and end-to-end encrypted. Only one person drives a pane at a time; everything is recorded in the audit log."
    }

    private func create() {
        isCreating = true
        error = nil
        let tab = workspace.session.activeTab
        let options = draft.options(
            inviter: workspace.multiplayer?.me?.name ?? WindowModel.deviceName,
            session: workspace.daemon?.layout.sessionId ?? (LaunchOptions.mock ? 1 : nil),
            tab: tab?.id.rawValue, pane: workspace.focusedPane?.rawValue)
        let summary = draft.summary
        Task {
            do {
                let invite = try await session.createInvite(options)
                withAnimation(DS.Motion.panel) {
                    created = invite
                    createdSummary = summary
                }
                draft.name = ""
            } catch {
                self.error = MultiplayerSession.describe(error)
            }
            isCreating = false
        }
    }

    // MARK: Guest

    private var yourAccess: some View {
        Section {
            if let me = session.me {
                LabeledContent("Joined as", value: me.name)
                LabeledContent("Role", value: roleWords(me.roles))
                LabeledContent("Covers", value: me.scope.title)
                if let expires = RelativeTime.string(ms: me.expiresMs) {
                    LabeledContent("Expires", value: expires)
                }
                if session.canApprove {
                    LabeledContent("Approvals", value: session.approvalPolicy.words)
                }
                ForEach(Role.invitable.filter { me.roles.contains($0) }, id: \.self) { role in
                    Label(role.summary, systemImage: role.systemImage)
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        } header: {
            SectionTitle("Your Access")
        } footer: {
            Text("Only the host's owner can invite people or see the audit log.")
        }
    }

    // MARK: People

    private var people: some View {
        Section {
            ForEach(session.participants.sortedForDisplay(me: session.myPrincipal), id: \.actor.device) { person in
                PersonRow(person: person, session: session, workspace: workspace)
                    .contextMenu { personMenu(person) }
                    .swipeActions {
                        if canRevoke(person) {
                            Button("Revoke", systemImage: "person.crop.circle.badge.xmark", role: .destructive) { revoking = person }
                        }
                    }
            }
            if session.participants.isEmpty {
                Text("Nobody else is here yet.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        } header: {
            SectionTitle("People Here", count: session.participants.count)
        }
    }

    @ViewBuilder private func personMenu(_ person: UnnamedCore.Participant) -> some View {
        if let pane = person.focus, session.isDriving(pane), person.roles.contains(.driver) || person.roles.contains(.owner),
           person.actor.principal != session.myPrincipal
        {
            Button("Give Control of \(paneTitle(pane))", systemImage: "keyboard") {
                Task { await session.giveControl(pane, to: person.actor.principal) }
            }
        }
        Button("Copy Device Key", systemImage: "doc.on.doc") { Pasteboard.copy(person.actor.device) }
        if canRevoke(person) {
            Divider()
            Button("Revoke Access…", systemImage: "person.crop.circle.badge.xmark", role: .destructive) { revoking = person }
        }
    }

    private func canRevoke(_ person: UnnamedCore.Participant) -> Bool {
        session.isOwner && person.grantId != nil && person.actor.principal != session.myPrincipal
    }

    private func paneTitle(_ pane: UInt64) -> String {
        workspace.paneTitle(pane)
    }

    private func revoke(_ person: UnnamedCore.Participant) async {
        let target: RevokeTarget = person.grantId.map { .grant(grantId: $0) } ?? .device(device: person.actor.device)
        if await session.revoke(target) != nil {
            ActiveWindow.model?.toasts.show(Toast("\(person.name) was removed", systemImage: "person.crop.circle.badge.xmark", style: .success))
        }
    }
}

extension Workspace {
    /// A pane in words for presence lines: its tab's name, plus the program in a split.
    func paneTitle(_ pane: UInt64) -> String {
        let id = PaneId(pane)
        guard let tab = session.tabs.first(where: { $0.root.panes.contains(id) }) else { return "pane \(pane)" }
        let title = self.title(of: tab)
        guard tab.root.panes.count > 1 else { return title }
        return "\(title) · \(agentName(id) ?? programName(of: id))"
    }
}

extension [UnnamedCore.Participant] {
    /// This device's principal first, then by arrival.
    func sortedForDisplay(me: String?) -> [UnnamedCore.Participant] {
        sorted { a, b in
            if (a.actor.principal == me) != (b.actor.principal == me) { return a.actor.principal == me }
            return a.sinceMs < b.sinceMs
        }
    }
}

/// Roles as four tiles: Viewer is always on; the others toggle.
private struct RolePicker: View {
    @Binding var roles: Set<Role>
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var columns: Int { sizeClass == .regular ? 4 : 2 }
    #else
    private var columns: Int { 4 }
    #endif

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s, alignment: .top), count: columns), spacing: DS.Space.s) {
            ForEach(Role.invitable, id: \.self) { role in
                tile(role)
            }
        }
    }

    private func tile(_ role: Role) -> some View {
        let locked = role == .viewer
        let on = locked || roles.contains(role)
        return Button {
            guard !locked else { return }
            withAnimation(DS.Motion.snappy) {
                if roles.contains(role) { roles.remove(role) } else { roles.insert(role) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.row) {
                    Image(systemName: role.systemImage)
                        .symbolVariant(on ? .fill : .none)
                        .foregroundStyle(on ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.textSecondary))
                        .frame(width: 18)
                    Text(role.title)
                        .font(DS.Font.rowTitleEmphasis)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                    Image(systemName: locked ? "lock.fill" : on ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(on && !locked ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.textTertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(role.summary)
                    .font(.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(DS.Space.gap10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(on ? AnyShapeStyle(DS.Palette.accent.opacity(0.10)) : AnyShapeStyle(DS.Palette.hoverFill), in: .rect(cornerRadius: DS.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .strokeBorder(on ? AnyShapeStyle(DS.Palette.accent.opacity(0.55)) : AnyShapeStyle(DS.Palette.hairline), lineWidth: on ? 1 : 0.5)
            }
            .contentShape(.rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(role.title)\(locked ? ", always included" : "")")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("role-\(role.title.lowercased())")
    }
}

/// The invite that was just created: QR code, link, copy and share.
private struct InviteResult: View {
    let invite: CreatedInvite
    let summary: String
    let onNew: () -> Void
    @State private var copied = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass == .regular }
    #else
    private var isWide: Bool { true }
    #endif

    var body: some View {
        Section {
            Group {
                if isWide {
                    HStack(alignment: .top, spacing: DS.Space.xl) {
                        qr
                        details.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.m) { qr.frame(maxWidth: .infinity); details }
                }
            }
            .padding(.vertical, DS.Space.xs)
            HStack(spacing: DS.Space.s) {
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("copy-invite")
                if let url = URL(string: invite.link) {
                    ShareLink(item: url, subject: Text("Join my terminal"), message: Text(summary)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primaryGlass)
                    .accessibilityIdentifier("share-invite")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DS.Space.s, leading: 0, bottom: 0, trailing: 0))
        } header: {
            HStack {
                SectionTitle("Invite Link")
                Spacer()
                Button("New Invite", action: onNew)
                    .font(DS.Font.rowSubtitle)
                    .accessibilityIdentifier("new-invite")
            }
        } footer: {
            Text("Anyone with this link or code joins with exactly these rights until it expires or you revoke it in Access & Grants.")
        }
    }

    private var qr: some View {
        QRCodeView(text: invite.qrPayload)
            .frame(width: 168, height: 168)
            .accessibilityIdentifier("invite-qr")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(summary)
                .font(DS.Font.rowTitleEmphasis)
                .accessibilityIdentifier("invite-summary")
            Text(invite.link)
                .font(DS.Font.literalSmall)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel("Invite link")
                .accessibilityIdentifier("invite-link")
            if let expires = RelativeTime.string(ms: invite.expiresMs) {
                Label("Expires \(expires)", systemImage: "clock")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
            } else {
                Label("Never expires", systemImage: "infinity")
                    .font(DS.Font.meta)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private func copy() {
        Pasteboard.copy(invite.link)
        withAnimation(DS.Motion.indicator) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(DS.Motion.indicator) { copied = false }
        }
    }
}

/// A person in the session: avatar, name, role, where they are, driving.
private struct PersonRow: View {
    let person: UnnamedCore.Participant
    let session: MultiplayerSession
    let workspace: Workspace

    var body: some View {
        let isMe = person.actor.principal == session.myPrincipal
        let driving = session.leases.values.filter { $0.holder == person.actor.principal && $0.mode == .leased }
        HStack(spacing: DS.Space.m) {
            PresenceAvatar(person.avatar, size: 30)
                .opacity(person.state == .away ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.row) {
                    Text(isMe ? "\(person.name) (you)" : person.name)
                        .font(DS.Font.rowTitle)
                        .lineLimit(1)
                    if !driving.isEmpty {
                        Label("Driving", systemImage: "keyboard.fill")
                            .labelStyle(.titleAndIcon)
                            .font(DS.Font.badge)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(person.avatar.color)
                            .background(person.avatar.color.opacity(0.14), in: .capsule)
                            .fixedSize()
                    }
                }
                Text(person.whereabouts(paneTitle: workspace.paneTitle))
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(person.typing ? AnyShapeStyle(person.avatar.color) : AnyShapeStyle(DS.Palette.textSecondary))
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(roleWords(person.roles))
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                if person.scope != .daemon {
                    Text(person.scope.title)
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("person-\(person.name)")
    }
}

/// A QR code drawn with Core Image, crisp at any size, dark modules on white with a quiet zone.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(.white, in: .rect(cornerRadius: DS.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control).strokeBorder(DS.Palette.hairline, lineWidth: 0.5)
                }
                .accessibilityLabel("QR code of the invite link")
        }
    }

    static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
