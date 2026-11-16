import Foundation
import HostKit
import Markdown

/// Image files a conversation names: a Read of an image, an attached image, or a Markdown image
/// standing alone in a paragraph. Only host paths qualify; web images are never fetched.
nonisolated enum ChatImages {
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"]

    static func isImage(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func path(read tool: TimelineTool) -> String? {
        guard tool.kind == .known(.read), tool.status != .known(.failed), tool.input.utf8.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: Data(tool.input.utf8)) as? [String: Any],
              let path = (object["file_path"] ?? object["path"]) as? String else { return nil }
        return hostPath(path)
    }

    static func paths(attachments: [TimelineAttachment]) -> [String] {
        attachments.compactMap { attachment in
            let typed = attachment.mediaType?.hasPrefix("image/") == true
            guard typed || isImage(attachment.path), attachment.path.hasPrefix("/") else { return nil }
            return attachment.path
        }
    }

    static func path(alone paragraph: any Markup) -> String? {
        guard paragraph is Paragraph else { return nil }
        let children = paragraph.children.filter { !($0 is SoftBreak) }
        guard children.count == 1, let image = children.first as? Markdown.Image, let source = image.source else { return nil }
        if let url = URL(string: source), url.isFileURL { return hostPath(url.path) }
        return hostPath(source)
    }

    static func hostPath(_ text: String) -> String? {
        guard (text.hasPrefix("/") || text.hasPrefix("~/")), !text.contains("\n"), text.utf8.count <= 4_096,
              isImage(text) else { return nil }
        return text
    }
}
