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

/// A participant's avatar: initials on their color, in whichever ink reads on it, with an
/// activity ring while they type (alone; a stack has no room for it).
public struct PresenceAvatar: View {
    let participant: Participant
    var size: CGFloat
    var showsActivity: Bool
    @Environment(\.self) private var environment

    public init(_ participant: Participant, size: CGFloat = DS.Size.avatar, showsActivity: Bool = true) {
        self.participant = participant
        self.size = size
        self.showsActivity = showsActivity
    }

    public var body: some View {
        let fill = participant.color.resolve(in: environment)
        Text(participant.initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(Self.ink(on: fill))
            .minimumScaleFactor(0.7)
            .frame(width: size, height: size)
            .background(participant.color, in: .circle)
            .overlay {
                if showsActivity {
                    Circle()
                        .strokeBorder(participant.color.opacity(participant.isActive ? 1 : 0), lineWidth: 1.5)
                        .padding(-3)
                }
            }
            .accessibilityLabel("\(participant.name), \(participant.role.rawValue)\(participant.isActive ? ", typing" : "")")
    }

    /// Black or white, whichever has more contrast with the fill (its components are linear).
    static func ink(on fill: Color.Resolved) -> Color {
        let luminance = 0.2126 * Double(fill.linearRed) + 0.7152 * Double(fill.linearGreen) + 0.0722 * Double(fill.linearBlue)
        return 1.05 / (luminance + 0.05) >= (luminance + 0.05) / 0.05 ? .white : .black
    }
}

/// Avatars side by side, whole, at most `limit`, then "+N".
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
        let extra = participants.count - shown.count
        HStack(spacing: max(2, size * 0.12)) {
            ForEach(shown) { participant in
                PresenceAvatar(participant, size: size, showsActivity: false)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.Palette.textSecondary)
                    .minimumScaleFactor(0.7)
                    .frame(width: size, height: size)
                    .background(DS.Palette.selectedFill, in: .circle)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
