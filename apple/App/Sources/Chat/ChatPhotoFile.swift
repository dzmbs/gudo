#if os(iOS)
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated final class ChatPhotoFile: Transferable, Sendable {
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static let maximumUploadBytes = 8 * 1_024 * 1_024
    let url: URL
    let bytes: Int

    init(url: URL, bytes: Int) { self.url = url; self.bytes = bytes }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let worker = Task.detached(priority: .userInitiated) { try prepare(url) }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
    }

    static func prepare(_ source: URL) throws -> ChatPhotoFile {
        try Task.checkCancellation()
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumInputBytes,
              let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw ChatPhotoError.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ChatPhotoError.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length <= maximumUploadBytes else { throw ChatPhotoError.invalidImage }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-photo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let url = directory.appending(path: "photo.jpg")
            try (encoded as Data).write(to: url, options: [.atomic, .completeFileProtection])
            return ChatPhotoFile(url: url, bytes: encoded.length)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

nonisolated enum ChatPhotoError: Error { case invalidImage, invalidPath }
#endif
