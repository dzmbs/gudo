import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// A drawing in the output, dragged somewhere. Other apps get a PNG and the `.excalidraw` scene; a pane of this app gets this reference too, so a drop
/// places the same drawing there (same host), uploads it (another host), or hands it to the
/// agent running in that pane.
public struct DrawingDragRef: Codable, Equatable, Sendable {
    public var hostId: String
    public var paneId: UInt64
    public var placementId: UInt64
    public var artifactId: UInt64
    /// The image shown (a blob on the source host).
    public var imageHash: String

    public static let typeIdentifier = "dev.gudo.drawing-ref"

    public init(hostId: String, paneId: UInt64, placementId: UInt64, artifactId: UInt64, imageHash: String) {
        self.hostId = hostId
        self.paneId = paneId
        self.placementId = placementId
        self.artifactId = artifactId
        self.imageHash = imageHash
    }
}

public enum DrawingTransfer {
    /// `.excalidraw` scenes (Excalidraw declares no UTI; imported, not owned).
    public static let sceneType = UTType(importedAs: "com.excalidraw.json", conformingTo: .json)

    public enum Failure: Error, Equatable {
        /// The image is not available (not downloaded, the host gone).
        case imageUnavailable
    }

    /// An item provider (iPad drags, `UIDragItem`): the PNG and the `.excalidraw` file, each
    /// produced only when the destination asks for it.
    public static func itemProvider(
        suggestedName: String = "Drawing",
        png: @escaping @Sendable () async -> Data?,
        sceneFile: @escaping @Sendable () async throws -> URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            Task {
                let data = await png()
                completion(data, data == nil ? Failure.imageUnavailable : nil)
            }
            return nil
        }
        provider.registerFileRepresentation(forTypeIdentifier: sceneType.identifier, fileOptions: [], visibility: .all) { completion in
            Task {
                do {
                    completion(try await sceneFile(), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

#if os(macOS)
/// A drawing dragged out on the Mac (`NSDraggingSource`): a promised PNG file (Finder, Mail),
/// plus PNG data, the `.excalidraw` scene (when at hand) and the in-app reference on the same
/// pasteboard item.
public final class DrawingFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let png: Data
    private let scene: Data?
    private let reference: DrawingDragRef
    private let name: String

    public init(png: Data, scene: Data?, ref: DrawingDragRef, name: String) {
        self.png = png
        self.scene = scene
        self.reference = ref
        self.name = name
        super.init()
        fileType = UTType.png.identifier
        delegate = self
    }

    public static let refType = NSPasteboard.PasteboardType(DrawingDragRef.typeIdentifier)
    public static let sceneType = NSPasteboard.PasteboardType(DrawingTransfer.sceneType.identifier)

    override public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard) + [.png, Self.refType]
        if scene != nil { types.append(Self.sceneType) }
        return types
    }

    override public func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        super.writableTypes(for: pasteboard).contains(type) ? super.writingOptions(forType: type, pasteboard: pasteboard) : []
    }

    override public func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .png: png
        case Self.refType: try? JSONEncoder().encode(reference)
        case Self.sceneType: scene
        default: super.pasteboardPropertyList(forType: type)
        }
    }

    public func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    // The completion-handler form: the compiler crashes emitting the `async` one's thunk
    // (Swift 6.4).
    public func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        do {
            try png.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// Drags of drawings copy (the drawing stays in its pane).
    public static let operation: NSDragOperation = .copy
}
#endif
