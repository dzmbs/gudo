#if os(iOS)
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated final class ChatPhotoFile: Transferable, Sendable {
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static let maximumUploadBytes = 8 * 1_024 * 1_024
    static let thumbnailPixels = 160
    let url: URL
    let bytes: Int
    /// What the pill calls it: the file's own name, or "Photo" for an image from the library.
    let name: String
    let thumbnail: Data?

    init(url: URL, bytes: Int, name: String = "Photo", thumbnail: Data? = nil) {
        self.url = url
        self.bytes = bytes
        self.name = name
        self.thumbnail = thumbnail
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let worker = Task.detached(priority: .userInitiated) { try prepare(url) }
            return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        }
    }

    /// An image as a metadata-free JPEG no larger than 2,048 pixels, with its thumbnail.
    static func prepare(_ source: URL, name: String = "Photo") throws -> ChatPhotoFile {
        try Task.checkCancellation()
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumInputBytes,
              let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ChatPhotoError.invalidImage }
        return try prepare(imageSource, name: name)
    }

    /// A pasted image, as `prepare(_:)` makes it.
    static func prepare(data: Data, name: String = "Pasted image") throws -> ChatPhotoFile {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ChatPhotoError.invalidImage }
        return try prepare(imageSource, name: name)
    }

    /// Any other file, copied as it is, up to the upload limit; an image goes through `prepare`.
    static func prepareFile(_ source: URL) throws -> ChatPhotoFile {
        try Task.checkCancellation()
        let name = source.lastPathComponent
        if let type = UTType(filenameExtension: source.pathExtension), type.conforms(to: .image) {
            return try prepare(source, name: name)
        }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumUploadBytes else { throw ChatPhotoError.invalidImage }
        let directory = try privateDirectory()
        do {
            let url = directory.appending(path: "upload" + (source.pathExtension.isEmpty ? "" : "." + source.pathExtension))
            try FileManager.default.copyItem(at: source, to: url)
            return ChatPhotoFile(url: url, bytes: size, name: name)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func privateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-photo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func prepare(_ imageSource: CGImageSource, name: String) throws -> ChatPhotoFile {
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
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
        let directory = try privateDirectory()
        do {
            let url = directory.appending(path: "photo.jpg")
            try (encoded as Data).write(to: url, options: [.atomic, .completeFileProtection])
            return ChatPhotoFile(url: url, bytes: encoded.length, name: name, thumbnail: thumbnail(of: imageSource))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

nonisolated extension ChatPhotoFile {
    private static func thumbnail(of imageSource: CGImageSource) -> Data? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ] as CFDictionary) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? encoded as Data : nil
    }
}

nonisolated enum ChatPhotoError: Error { case invalidImage, invalidPath }
#endif
