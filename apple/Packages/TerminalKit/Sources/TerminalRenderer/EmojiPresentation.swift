/// How a grapheme cluster asks to be drawn (UTS #51): VS15 or VS16 decide; without one, the
/// first character's `Emoji_Presentation` property does.
enum EmojiPresentation: Equatable {
    case text, emoji

    static let textSelector = Unicode.Scalar(0xFE0E)!
    static let emojiSelector = Unicode.Scalar(0xFE0F)!

    init(_ scalars: [Unicode.Scalar]) {
        if scalars.contains(Self.emojiSelector) {
            self = .emoji
        } else if scalars.contains(Self.textSelector) {
            self = .text
        } else {
            self = scalars.first?.properties.isEmojiPresentation == true ? .emoji : .text
        }
    }
}
