import DesignSystem
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Who is in this session, their roles, and a link to invite someone.
struct InviteSheet: View {
    let sessionTitle: String
    let participants: [Participant]

    private enum Access: String, CaseIterable, Identifiable {
        case view, type
        var id: String { rawValue }
        var title: String { self == .view ? "Can view" : "Can type" }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var roles: [Participant.ID: Participant.Role] = [:]
    @State private var access = Access.view
    @State private var copied = false

    /// Stand-in invite token until the daemon issues real ones.
    private var link: String {
        "https://join.\(Brand.name.isEmpty ? "example" : Brand.name).dev/\(access == .view ? "v" : "t")/7KQ-M2D-X9P"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: DS.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sessionTitle)
                                .font(DS.Font.title)
                                .lineLimit(1)
                            Text(participants.count == 1 ? "Only you" : "\(participants.count) people")
                                .font(DS.Font.rowSubtitle)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        PresenceStack(participants)
                    }
                }

                Section {
                    ForEach(participants) { person in
                        PersonRow(person: person, role: binding(for: person))
                    }
                } header: {
                    SectionTitle("People", count: participants.count)
                }

                Section {
                    Picker("Access", selection: $access) {
                        ForEach(Access.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(link)
                        .font(DS.Font.literalSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityLabel("Invite link")
                    HStack(spacing: DS.Space.s) {
                        Button(action: copy) {
                            Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        if let url = URL(string: link) {
                            ShareLink(item: url, subject: Text(sessionTitle)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    SectionTitle("Invite")
                } footer: {
                    Text("Links expire in 24 hours. Viewers see output; only people who can type send input.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .phoneDetents([.medium, .large])
        #else
        .frame(minWidth: 440, idealWidth: 480, minHeight: 440)
        #endif
    }

    private func binding(for person: Participant) -> Binding<Participant.Role> {
        Binding(get: { roles[person.id] ?? person.role }, set: { roles[person.id] = $0 })
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = link
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        #endif
        withAnimation(DS.Motion.indicator) { copied = true }
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(DS.Motion.indicator) { copied = false }
        }
    }
}

private struct PersonRow: View {
    let person: Participant
    @Binding var role: Participant.Role

    var body: some View {
        HStack(spacing: DS.Space.m) {
            PresenceAvatar(person, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(DS.Font.rowTitle)
                    .lineLimit(1)
                if person.isActive {
                    Text("Typing")
                        .font(DS.Font.badge)
                        .foregroundStyle(person.color)
                }
            }
            Spacer()
            if person.role == .owner {
                Text("Owner")
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Role", selection: $role) {
                    Text("Can type").tag(Participant.Role.editor)
                    Text("Can view").tag(Participant.Role.viewer)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }
}
