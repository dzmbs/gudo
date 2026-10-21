import SwiftUI

/// Someone else looking at (or typing into) the same session.
nonisolated public struct Participant: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case owner, editor, viewer }

    public var id: String
    public var name: String
    public var role: Role
    /// Typing right now; drawn as a ring in the participant's color.
    public var isActive: Bool
    /// Index into the presence hue list, stable per participant.
    public var hue: Int

    public init(id: String, name: String, role: Role = .editor, isActive: Bool = false, hue: Int = 0) {
        self.id = id
        self.name = name
        self.role = role
        self.isActive = isActive
        self.hue = hue
    }

    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Presence hues are the theme's own ANSI hues, so cursors and avatars match the terminal
    /// (palette 4, 5, 6, 2, 3).
    public var color: ChromeStyle {
        let hues = [4, 5, 6, 2, 3]
        return DS.Palette.ansi(hues[abs(hue) % hues.count])
    }
}

/// A participant's avatar: initials on their color, with an activity ring while they type.
public struct PresenceAvatar: View {
    let participant: Participant
    var size: CGFloat

    public init(_ participant: Participant, size: CGFloat = DS.Size.avatar) {
        self.participant = participant
        self.size = size
    }

    public var body: some View {
        Text(participant.initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(participant.color, in: .circle)
            .overlay {
                Circle()
                    .strokeBorder(participant.color.opacity(participant.isActive ? 1 : 0), lineWidth: 1.5)
                    .padding(-3)
            }
            .accessibilityLabel("\(participant.name), \(participant.role.rawValue)\(participant.isActive ? ", typing" : "")")
    }
}

/// Overlapping avatars, at most `limit`, then "+N" (Figma/Linear presence stacks).
public struct PresenceStack: View {
    let participants: [Participant]
    var limit: Int

    public init(_ participants: [Participant], limit: Int = 3) {
        self.participants = participants
        self.limit = limit
    }

    public var body: some View {
        HStack(spacing: -4) {
            // Later avatars sit under earlier ones so every set of initials stays readable.
            ForEach(Array(participants.prefix(limit).enumerated()), id: \.element.id) { index, participant in
                PresenceAvatar(participant)
                    .background(Circle().fill(DS.Palette.base).padding(-1.5))
                    .zIndex(Double(limit - index))
            }
            if participants.count > limit {
                Text("+\(participants.count - limit)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.Size.avatar, height: DS.Size.avatar)
                    .background(DS.Palette.selectedFill, in: .circle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
