import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the system clipboard holds for a drawing, in the form the canvas page's `paste` takes:
/// an image as base64 PNG, and text. The page cannot read the clipboard itself.
@MainActor
enum CanvasClipboard {
    #if os(iOS)
    typealias Pasteboard = UIPasteboard
    #else
    typealias Pasteboard = NSPasteboard
    #endif

    /// The system's clipboard; tests give it one of their own.
    static var pasteboard: Pasteboard = .general

    static func contents(of pasteboard: Pasteboard = CanvasClipboard.pasteboard) -> [String: Any] {
        var contents: [String: Any] = [:]
        if let png = image(in: pasteboard) {
            contents["image"] = png.base64EncodedString()
            contents["mimeType"] = "image/png"
        }
        if let text = text(in: pasteboard), !text.isEmpty {
            contents["text"] = text
        }
        return contents
    }

    static func hasContents(_ pasteboard: Pasteboard = CanvasClipboard.pasteboard) -> Bool {
        #if os(iOS)
        pasteboard.hasImages || pasteboard.hasStrings
        #else
        pasteboard.availableType(from: [.png, .tiff, .string, .fileURL]) != nil
        #endif
    }

    #if os(iOS)
    private static func text(in pasteboard: Pasteboard) -> String? {
        pasteboard.hasStrings ? pasteboard.string : nil
    }

    private static func image(in pasteboard: Pasteboard) -> Data? {
        guard pasteboard.hasImages else { return nil }
        if let png = pasteboard.data(forPasteboardType: UTType.png.identifier) { return png }
        return pasteboard.image?.pngData()
    }
    #else
    private static func text(in pasteboard: Pasteboard) -> String? {
        pasteboard.string(forType: .string)
    }

    /// A copied image, or an image file copied in the Finder. Not PDF: text copied from a
    /// document often carries a PDF picture of itself.
    private static func image(in pasteboard: Pasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        if let tiff = pasteboard.data(forType: .tiff) { return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        guard let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first,
              let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation
        else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
    #endif
}
