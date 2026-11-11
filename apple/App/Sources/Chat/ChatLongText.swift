import Foundation
import HostKit

nonisolated enum ChatLongText {
    static func showAllTitle(_ content: TimelineOutputReference) -> String {
        "Show all " + size(content)
    }

    static func previewNote(_ content: TimelineOutputReference) -> String {
        "Start of " + size(content)
    }

    static func title(_ role: TimelineTextRole) -> String {
        switch role {
        case .known(.user): "Message"
        case .known(.thinking): "Thinking"
        case .known(.assistant), .unknown: "Reply"
        }
    }

    static func rendersMarkdown(_ role: TimelineTextRole) -> Bool {
        role != .known(.user) && role != .known(.thinking)
    }

    private static func size(_ content: TimelineOutputReference) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: content.bytes), countStyle: .file)
    }
}
