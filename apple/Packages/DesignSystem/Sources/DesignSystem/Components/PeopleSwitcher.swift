import SwiftUI

/// One person in a shared session, for the people switcher.
public struct PeopleSwitcherPerson: Identifiable {
    /// What following them is keyed by (their principal).
    public var id: String
    public var avatar: Participant
    public var name: String
    /// "Typing in Claude Code", "Away", "Following you".
    public var detail: String?
    public var isFollowed: Bool
    public var isMe: Bool

    public init(id: String, avatar: Participant, name: String, detail: String? = nil, isFollowed: Bool = false, isMe: Bool = false) {
        self.id = id
        self.avatar = avatar
        self.name = name
        self.detail = detail
        self.isFollowed = isFollowed
        self.isMe = isMe
    }
}

/// person with their avatar and what they are doing, ✓ on the one this window follows; a tap
/// follows (or stops). Then commands (Share Session…).
public struct PeopleSwitcher: View {
    let people: [PeopleSwitcherPerson]
    let commands: [HostSwitcherCommand]
    let onFollow: (String?) -> Void
    let onDismiss: () -> Void

    @State private var highlighted: String?
    @Namespace private var highlight

    public init(
        people: [PeopleSwitcherPerson], commands: [HostSwitcherCommand],
        onFollow: @escaping (String?) -> Void, onDismiss: @escaping () -> Void
    ) {
        self.people = people
        self.commands = commands
        self.onFollow = onFollow
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(people.count == 1 ? "1 person here" : "\(people.count) people here")
                .font(DS.Font.sectionSmall)
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.m + DS.Space.xxs)
                .padding(.top, DS.Space.m)
                .padding(.bottom, DS.Space.xs)
            VStack(spacing: 1) {
                ForEach(people) { person in personRow(person) }
                if !people.isEmpty, !commands.isEmpty {
                    Hairline()
                        .padding(.vertical, DS.Space.xs)
                        .padding(.horizontal, DS.Space.s)
                }
                ForEach(commands) { command in commandRow(command) }
            }
            .padding(DS.Space.row)
        }
        .frame(width: DS.Size.switcherWidth)
        .chromeContent()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("people-switcher")
    }

    private func personRow(_ person: PeopleSwitcherPerson) -> some View {
        Button {
            guard !person.isMe else { return }
            onDismiss()
            onFollow(person.isFollowed ? nil : person.id)
        } label: {
            HStack(spacing: DS.Space.gap10) {
                PresenceAvatar(person.avatar, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(person.isMe ? "\(person.name) (you)" : person.name)
                        .font(.body)
                        .foregroundStyle(DS.Palette.text)
                        .lineLimit(1)
                    if let detail = person.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                .reservesSubtitleLine()
                Spacer(minLength: DS.Space.s)
                if !person.isMe {
                    Text(person.isFollowed ? "Following" : "Follow")
                        .font(DS.Font.menuShortcut)
                        .foregroundStyle(person.isFollowed ? DS.Palette.accent : DS.Palette.textTertiary)
                        .opacity(person.isFollowed || highlighted == person.id ? 1 : 0)
                }
                SwitcherCheck(person.isFollowed)
            }
            .switcherRow(isHighlighted: highlighted == person.id, in: highlight)
        }
        .buttonStyle(.plain)
        .disabled(person.isMe)
        .onHover { if $0 { withAnimation(DS.Motion.menu) { highlighted = person.id } } }
        .accessibilityLabel(person.isMe ? "\(person.name), you" : person.isFollowed ? "Stop Following \(person.name)" : "Follow \(person.name)")
        .accessibilityValue(person.detail ?? "")
        .accessibilityAddTraits(person.isFollowed ? .isSelected : [])
        .accessibilityIdentifier(person.isMe ? "people-me" : "follow-\(person.name)")
    }

    private func commandRow(_ command: HostSwitcherCommand) -> some View {
        Button {
            onDismiss()
            command.perform()
        } label: {
            HStack(spacing: DS.Space.gap10) {
                Image(systemName: command.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: 24)
                Text(command.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                ShortcutLabel(command.shortcut).font(DS.Font.menuShortcut)
                Color.clear.frame(width: 16, height: 1)
            }
            .switcherRow(isHighlighted: highlighted == command.id, in: highlight)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { withAnimation(DS.Motion.menu) { highlighted = command.id } } }
        .accessibilityIdentifier("people-\(command.id)")
    }
}
