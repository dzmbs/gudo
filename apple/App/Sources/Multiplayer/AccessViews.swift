import DesignSystem
import HostKit
import SwiftUI
import GudoCore

/// The owner's access list: every invite with who redeemed it, and every device, each revocable.
struct GrantsView: View {
    let session: MultiplayerSession
    var hostName = "this host"
    @State private var revoking: GrantInfo?
    @State private var removing: DeviceInfo?
    @State private var loaded = false

    private var active: [GrantInfo] { session.grants.filter { !$0.revoked && !isExpired($0) }.sorted { $0.grant.issuedAtMs > $1.grant.issuedAtMs } }
    private var ended: [GrantInfo] { session.grants.filter { $0.revoked || isExpired($0) }.sorted { $0.grant.issuedAtMs > $1.grant.issuedAtMs } }

    var body: some View {
        List {
            HostAlertsSection(session: session)
            Section {
                if active.isEmpty {
                    Text(loaded ? "No active invites. Create one in Share Session." : "Loading invites…")
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ForEach(active, id: \.grant.grantId) { info in
                    GrantRow(info: info, session: session)
                        // Red, not `.destructive`: the row stays until the revocation is confirmed.
                        .swipeActions { Button("Revoke") { revoking = info }.tint(.red) }
                        .contextMenu {
                            Button("Copy Grant ID", systemImage: "doc.on.doc") { Pasteboard.copy(info.grant.grantId) }
                            Button("Revoke…", systemImage: "xmark.circle", role: .destructive) { revoking = info }
                        }
                }
            } header: {
                SectionTitle("Active Invites", count: active.count)
            }
            .chromeRows()

            DevicesSections(session: session, hostName: hostName, removing: $removing)

            if !ended.isEmpty {
                Section {
                    ForEach(ended, id: \.grant.grantId) { info in
                        GrantRow(info: info, session: session)
                    }
                } header: {
                    SectionTitle("Ended", count: ended.count)
                }
                .chromeRows()
            }
        }
        .chromeGrouped()
        .navigationTitle("Access & Grants")
        .refreshable { await session.refreshGrants() }
        .task {
            await session.refreshGrants()
            loaded = true
        }
        .confirmationDialog(
            "Revoke \(revoking.map { $0.grant.label.isEmpty ? "this invite" : $0.grant.label } ?? "")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible, presenting: revoking
        ) { info in
            Button("Revoke", role: .destructive) {
                Task { await session.revoke(.grant(grantId: info.grant.grantId)) }
            }
        } message: { _ in
            Text("Everyone who joined with it, and anyone they invited, is disconnected now.")
        }
        .modifier(RemoveDeviceDialog(session: session, hostName: hostName, device: $removing))
        .accessibilityIdentifier("grants-list")
    }

    private func isExpired(_ info: GrantInfo) -> Bool {
        guard let expires = info.grant.expiresMs else { return false }
        return Double(expires) / 1000 < Date.now.timeIntervalSince1970
    }
}

struct GrantRow: View {
    let info: GrantInfo
    let session: MultiplayerSession
    /// With both set, the row shows Copy Link and Revoke buttons.
    var onCopy: (() -> Void)?
    var onRevoke: (() -> Void)?
    var copied = false

    var body: some View {
        let grant = info.grant
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: info.revoked ? "xmark.circle" : grant.roles.contains(.driver) ? "keyboard" : grant.roles.contains(.prompter) ? "text.bubble" : "eye")
                .foregroundStyle(info.revoked ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(DS.Palette.textSecondary))
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.row) {
                    Text(grant.label.isEmpty ? "Guest" : grant.label)
                        .font(DS.Font.rowTitleEmphasis)
                    if grant.delegate {
                        Text("Can invite")
                            .font(DS.Font.badge)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(DS.Palette.selectedFill, in: .capsule)
                    }
                }
                Text("\(roleWords(grant.roles)) · \(grant.scope.title)")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Palette.textSecondary)
                Text(statusLine)
                    .font(DS.Font.meta)
                    .foregroundStyle(info.revoked ? AnyShapeStyle(DS.Palette.error) : AnyShapeStyle(DS.Palette.textTertiary))
            }
            Spacer(minLength: 0)
            if let onCopy, let onRevoke {
                HStack(spacing: 0) {
                    Button(action: onCopy) {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .help("Copy Link")
                    .accessibilityIdentifier("copy-link-\(grant.label)")
                    Button(role: .destructive, action: onRevoke) {
                        Label("Revoke", systemImage: "xmark.circle")
                    }
                    .help("Revoke")
                    .accessibilityIdentifier("revoke-link-\(grant.label)")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(QuietButtonStyle())
            } else {
                Text(groupedHex(grant.grantId, groups: 2))
                    .font(DS.Font.literalSmall)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: onCopy == nil ? .combine : .contain)
        .accessibilityIdentifier("grant-\(grant.label)")
    }

    private var statusLine: String {
        let grant = info.grant
        var parts: [String] = []
        if onCopy != nil, let created = RelativeTime.string(ms: grant.issuedAtMs) {
            parts.append("Created \(created)")
        }
        if info.revoked {
            parts.append("Revoked")
        } else if let expires = grant.expiresMs {
            let date = Date(timeIntervalSince1970: Double(expires) / 1000)
            parts.append(date < .now ? "Expired \(RelativeTime.string(date))" : "Expires \(RelativeTime.string(date))")
        } else {
            parts.append("Never expires")
        }
        let used = UInt32(info.bound.count)
        parts.append(grant.maxUses.map { used >= $0 ? "all \($0) used" : "\(used) of \($0) used, \($0 - used) left" } ?? "\(used) joined")
        if info.parent != nil { parts.append("delegated") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Audit log

struct AuditLogView: View {
    let session: MultiplayerSession
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var expanded: Set<UInt64> = []

    enum Filter: String, CaseIterable, Identifiable {
        case all, approvals, access, control
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .approvals: "Approvals"
            case .access: "Access"
            case .control: "Control"
            }
        }

        func matches(_ kind: AuditKind) -> Bool {
            switch self {
            case .all: true
            case .approvals: [.approval, .claim, .policy].contains(kind)
            case .access: [.join, .leave, .paired, .grantRegistered, .grantRedeemed, .revoked, .denied, .knock, .knockAnswered].contains(kind)
            case .control: kind == .lease || kind == .prompt
            }
        }
    }

    private var records: [AuditRecord] {
        let all = session.auditPage?.records ?? []
        return all.reversed().filter { record in
            guard filter.matches(record.kind) else { return false }
            guard !query.isEmpty else { return true }
            let haystack = [record.detail, session.name(of: record.actor), record.approval?.summary ?? "", record.approval?.tool ?? ""].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                chainStatus
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("audit-filter")
            }
            .chromeRows()
            Section {
                if session.auditPage == nil {
                    Text("Reading the log…").foregroundStyle(DS.Palette.textSecondary)
                } else if records.isEmpty {
                    Text(query.isEmpty ? "Nothing recorded yet." : "No records match “\(query)”.").foregroundStyle(DS.Palette.textSecondary)
                }
                ForEach(records, id: \.seq) { record in
                    AuditRow(record: record, session: session, isExpanded: expanded.contains(record.seq))
                        .contentShape(.rect)
                        .onTapGesture {
                            guard record.approval != nil else { return }
                            withAnimation(DS.Motion.snappy) {
                                if expanded.contains(record.seq) { expanded.remove(record.seq) } else { expanded.insert(record.seq) }
                            }
                        }
                }
            } header: {
                SectionTitle(filter == .all ? "Newest First" : filter.title, count: records.count)
            }
            .chromeRows()
        }
        .chromeGrouped()
        .navigationTitle("Audit Log")
        .searchable(text: $query, prompt: "Filter by person, tool or command")
        .refreshable { await session.loadAudit() }
        .task { await session.loadAudit() }
        .accessibilityIdentifier("audit-list")
    }

    @ViewBuilder private var chainStatus: some View {
        if let page = session.auditPage {
            HStack(spacing: DS.Space.m) {
                Image(systemName: page.chainOk ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                    .font(.title2)
                    .foregroundStyle(page.chainOk ? DS.Palette.done : DS.Palette.error)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.chainOk ? "Log intact" : "Log was altered")
                        .font(DS.Font.rowTitleEmphasis)
                    Text(page.chainOk
                         ? "\(page.total) records; every hash and approval signature re-verified on the host."
                         : "A record does not match the hash chain or a signature failed. Treat this host's history as untrusted.")
                        .font(DS.Font.rowSubtitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(page.chainOk ? "audit-chain-ok" : "audit-chain-broken")
        }
    }
}

private struct AuditRow: View {
    let record: AuditRecord
    let session: MultiplayerSession
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                Image(systemName: glyph)
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.rowTitle)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: DS.Space.s)
                VStack(alignment: .trailing, spacing: 2) {
                    let date = Date(timeIntervalSince1970: Double(record.atMs) / 1000)
                    Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textSecondary)
                    Text("#\(record.seq)")
                        .font(DS.Font.meta)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            if let approval = record.approval {
                approvalCard(approval)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("audit-\(record.seq)")
    }

    private var actorName: String { session.name(of: record.actor) }

    private var title: String {
        switch record.kind {
        case .approval:
            let approved = record.approval.map { Self.isApproval($0.option) } ?? true
            return "\(actorName) \(approved ? "approved" : "denied") \(record.approval?.tool ?? "a request")"
        case .join: return "\(actorName) joined"
        case .leave: return "\(actorName) left"
        case .paired: return "\(actorName) paired a device"
        case .grantRegistered: return "Invite created"
        case .grantRedeemed: return "\(actorName) used an invite"
        case .revoked: return "Access revoked"
        case .lease: return "\(actorName) took control"
        case .prompt: return "\(actorName) prompted an agent"
        case .denied: return "Refused"
        // A knocker is nobody the host knows yet: the record names them.
        case .knock: return (record.detail.components(separatedBy: " knocked").first ?? actorName) + " knocked"
        case .knockAnswered: return record.detail.hasPrefix("admitted") ? "Let someone in" : record.detail.hasSuffix("stopped waiting") ? "Stopped waiting" : "Turned someone away"
        case .policy: return "Approval rules changed"
        case .claim: return "\(actorName) \(record.detail.contains(" released ") ? "released" : "claimed") a request"
        }
    }

    /// The daemon's detail minus what the title already says: "Mira Holt joined as viewer on
    /// session:1" under "Mira Holt joined" becomes "As viewer on session:1".
    private var subtitle: String? {
        // An approval's command is in its card below.
        if record.approval != nil { return nil }
        var detail = record.detail.trimmingCharacters(in: .whitespaces)
        for name in [actorName, record.actor.map { session.name(of: $0) } ?? ""] where !name.isEmpty && detail.hasPrefix(name) {
            detail = String(detail.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        }
        let verb = title.hasPrefix(actorName) ? String(title.dropFirst(actorName.count)).trimmingCharacters(in: .whitespaces) : title
        if detail.lowercased() == verb.lowercased() || detail.isEmpty { return nil }
        if detail.lowercased().hasPrefix(verb.lowercased() + " ") { detail = String(detail.dropFirst(verb.count + 1)) }
        return detail.prefix(1).uppercased() + detail.dropFirst()
    }

    static func isApproval(_ label: String) -> Bool {
        let lower = label.lowercased()
        return !["no", "deny", "reject", "decline", "cancel", "abort"].contains { lower.hasPrefix($0) }
    }

    private var glyph: String {
        switch record.kind {
        case .approval: record.approval.map { Self.isApproval($0.option) ? "checkmark.seal.fill" : "xmark.seal.fill" } ?? "checkmark.seal"
        case .join: "person.crop.circle.badge.checkmark"
        case .leave: "person.crop.circle.badge.minus"
        case .paired: "link"
        case .grantRegistered: "link.badge.plus"
        case .grantRedeemed: "ticket"
        case .revoked: "person.crop.circle.badge.xmark"
        case .lease: "keyboard"
        case .prompt: "text.bubble"
        case .denied: "hand.raised.fill"
        case .knock: "hand.wave"
        case .knockAnswered: record.detail.hasPrefix("admitted") ? "door.left.hand.open" : "door.left.hand.closed"
        case .policy: "checkmark.shield"
        case .claim: "hand.point.up.left"
        }
    }

    private var tint: ChromeStyle {
        switch record.kind {
        case .approval: record.approval.map { Self.isApproval($0.option) ? DS.Palette.done : DS.Palette.blocked } ?? DS.Palette.textSecondary
        case .denied, .revoked: DS.Palette.error
        default: DS.Palette.textSecondary
        }
    }

    @ViewBuilder private func approvalCard(_ approval: ApprovalAudit) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.row) {
            Text(approval.summary)
                .font(DS.Font.literalSmall)
                .lineLimit(isExpanded ? nil : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DS.Space.s) {
                Label("Signed by \(actorName)", systemImage: "signature")
                Spacer()
                Text("Option “\(approval.option)”")
            }
            .font(DS.Font.meta)
            .foregroundStyle(DS.Palette.textSecondary)
            if isExpanded {
                Divider()
                field("Signer device", groupedHex(record.actor?.device ?? "", groups: 8))
                field("Signature", groupedHex(Self.hex(approval.sig), groups: 8) + "…")
                field("Agent request", approval.agentRequest)
                field("Record hash", groupedHex(Self.hex(record.hash), groups: 6) + "…")
            } else {
                Text("Tap for the signer's key and signature")
                    .font(.caption2)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(DS.Space.gap10)
        .background(DS.Palette.hoverFill, in: .rect(cornerRadius: DS.Radius.control))
        .padding(.leading, 22 + DS.Space.m)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(DS.Palette.textTertiary)
            Text(value).font(DS.Font.literalSmall).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Managing sharing

struct ActiveLinksSection: View {
    let session: MultiplayerSession
    @State private var revoking: GrantInfo?
    @State private var copied: String?

    var body: some View {
        let links = session.activeGrants
        Section {
            ForEach(links, id: \.grant.grantId) { info in
                GrantRow(info: info, session: session, onCopy: { copy(info) }, onRevoke: { revoking = info }, copied: copied == info.grant.grantId)
                    .contextMenu {
                        Button("Copy Link", systemImage: "doc.on.doc") { copy(info) }
                        Button("Revoke…", systemImage: "xmark.circle", role: .destructive) { revoking = info }
                    }
            }
            if links.isEmpty {
                Text("No links. Anyone you invite shows up here until the link expires or you revoke it.")
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        } header: {
            SectionTitle("Active Links", count: links.count)
        }
        .confirmationDialog(
            "Revoke \(revoking.map { $0.grant.label.isEmpty ? "this link" : "“\($0.grant.label)”" } ?? "")?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible, presenting: revoking
        ) { info in
            Button("Revoke Link", role: .destructive) {
                Task {
                    if await session.revoke(.grant(grantId: info.grant.grantId)) != nil {
                        ActiveWindow.model?.toasts.show(Toast("Link revoked", systemImage: "xmark.circle", style: .success))
                    }
                }
            }
        } message: { _ in
            Text("The link stops working now. Everyone who joined with it, and anyone they invited, is disconnected.")
        }
        .accessibilityIdentifier("active-links")
        .task { await session.refreshGrants() }
    }

    private func copy(_ info: GrantInfo) {
        Task {
            guard let link = await session.link(for: info) else { return }
            Pasteboard.copySecret(link)
            withAnimation(DS.Motion.indicator) { copied = info.grant.grantId }
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(DS.Motion.indicator) { if copied == info.grant.grantId { copied = nil } }
        }
    }
}

struct RemovePersonDialog: ViewModifier {
    let session: MultiplayerSession
    @Binding var person: GudoCore.Participant?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove \(person?.name ?? "")?", isPresented: Binding(get: { person != nil }, set: { if !$0 { person = nil } }),
            titleVisibility: .visible, presenting: person
        ) { person in
            Button("Remove", role: .destructive) {
                Task {
                    if await session.remove(person) != nil {
                        ActiveWindow.model?.toasts.show(Toast("\(person.name) was removed", systemImage: "person.crop.circle.badge.xmark", style: .success))
                    }
                }
            }
        } message: { person in
            Text("\(person.name) is disconnected now and can't rejoin from this device. Anything they started keeps running; their link still works for others until you revoke it.")
        }
    }
}
