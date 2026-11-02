import SwiftUI

/// Someone else looking at (or typing into) the same session.
nonisolated public struct Participant: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case owner, editor, viewer }

    public var id: String
    public var name: String
    public var role: Role
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

    /// The theme's own ANSI hues, so cursors and avatars match the terminal.
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

/// Overlapping avatars, at most `limit`, then "+N". Each avatar cuts a thin gap out of the one under it, so the stack reads on any background (a selected
/// sidebar row, glass, the terminal) without a ring in a guessed colour.
public struct PresenceStack: View {
    let participants: [Participant]
    var limit: Int
    var size: CGFloat

    public init(_ participants: [Participant], limit: Int = 3, size: CGFloat = DS.Size.avatar) {
        self.participants = participants
        self.limit = limit
        self.size = size
    }

    public var body: some View {
        let shown = Array(participants.prefix(limit))
        HStack(spacing: -overlap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, participant in
                PresenceAvatar(participant, size: size)
                    .mask { cutout(index > 0) }
                    .zIndex(Double(limit - index))
            }
            if participants.count > limit {
                Text("+\(participants.count - limit)")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: size, height: size)
                    .background(DS.Palette.selectedFill, in: .circle)
                    .mask { cutout(true) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var overlap: CGFloat { size * 0.28 }

    /// Everything but a ring around the avatar to the left, which overlaps this one.
    private func cutout(_ hasLeftNeighbour: Bool) -> some View {
        Rectangle()
            .overlay {
                if hasLeftNeighbour {
                    Circle()
                        .frame(width: size + 3, height: size + 3)
                        .offset(x: -(size - overlap))
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }
}
