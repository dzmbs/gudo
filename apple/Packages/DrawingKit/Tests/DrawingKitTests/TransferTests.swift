import Foundation
import Testing
import UniformTypeIdentifiers
@testable import DrawingKit
#if os(macOS)
import AppKit
#endif

/// A drawing dragged out of a pane: what other apps and this app's panes get. The Mac's
/// `NSDraggingSource` writes a `DrawingFilePromise`; the iPad's `UIDragInteraction` an item
/// provider. Both are checked here without UI (no app, no screen).
@MainActor @Suite struct TransferTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    private let scene = Data(#"{"type":"excalidraw","version":2,"elements":[]}"#.utf8)
    private let reference = DrawingDragRef(hostId: "studio", paneId: 4, placementId: 9, artifactId: 12, imageHash: "abc")

    @Test func itemProviderOffersThePNGAndTheSceneOnDemand() async throws {
        let sceneURL = FileManager.default.temporaryDirectory.appending(path: "drawing-\(UUID().uuidString).excalidraw")
        try scene.write(to: sceneURL)
        let asked = Asked()
        let provider = DrawingTransfer.itemProvider(
            png: { asked.png = true; return png },
            sceneFile: { asked.scene = true; return sceneURL })
        #expect(provider.suggestedName == "Drawing")
        #expect(provider.registeredTypeIdentifiers == [UTType.png.identifier, "com.excalidraw.json"])
        #expect(!asked.png && !asked.scene, "nothing is produced before a destination asks")

        let data = try await load(provider, UTType.png.identifier)
        #expect(data == png)
        #expect(asked.png && !asked.scene)
        let file = try await loadFile(provider, "com.excalidraw.json")
        #expect(file == scene)
    }

    @Test func aMissingImageFailsTheDrop() async {
        let provider = DrawingTransfer.itemProvider(png: { nil }, sceneFile: { throw DrawingTransfer.Failure.imageUnavailable })
        await #expect(throws: (any Error).self) { try await load(provider, UTType.png.identifier) }
        await #expect(throws: (any Error).self) { try await loadFile(provider, "com.excalidraw.json") }
    }

    #if os(macOS)
    @Test func macDragCarriesAPromisedFilePNGSceneAndReference() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("drawing-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let promise = DrawingFilePromise(png: png, scene: scene, ref: reference, name: "Drawing.png")
        let types = promise.writableTypes(for: pasteboard)
        // Finder and Mail get a promised file; image apps PNG data; Excalidraw the scene; this
        // app's panes the drawing itself.
        #expect(types.contains(NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")) || types.contains(.fileURL)
            || types.contains(NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise as String)))
        #expect(types.contains(.png))
        #expect(types.contains(DrawingFilePromise.refType))
        #expect(types.contains(DrawingFilePromise.sceneType))
        #expect(promise.pasteboardPropertyList(forType: .png) as? Data == png)
        #expect(promise.pasteboardPropertyList(forType: DrawingFilePromise.sceneType) as? Data == scene)
        let refData = try #require(promise.pasteboardPropertyList(forType: DrawingFilePromise.refType) as? Data)
        #expect(try JSONDecoder().decode(DrawingDragRef.self, from: refData) == reference)
        // Our own types are written at once, not promised.
        #expect(promise.writingOptions(forType: .png, pasteboard: pasteboard) == [])
        #expect(DrawingFilePromise.operation == .copy, "dragging out copies; the drawing stays")

        // On a pasteboard: what a drop target reads back.
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([promise]))
        #expect(pasteboard.data(forType: .png) == png)
        #expect(pasteboard.data(forType: DrawingFilePromise.sceneType) == scene)
        let read = try #require(pasteboard.data(forType: DrawingFilePromise.refType))
        #expect(try JSONDecoder().decode(DrawingDragRef.self, from: read) == reference)
    }

    @Test func macDragWithoutTheSceneOffersNone() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("drawing-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let promise = DrawingFilePromise(png: png, scene: nil, ref: reference, name: "Drawing.png")
        #expect(!promise.writableTypes(for: pasteboard).contains(DrawingFilePromise.sceneType))
        #expect(promise.pasteboardPropertyList(forType: DrawingFilePromise.sceneType) == nil)
    }

    @Test func macPromisedFileIsThePNG() async throws {
        let promise = DrawingFilePromise(png: png, scene: nil, ref: reference, name: "Drawing.png")
        #expect(promise.filePromiseProvider(promise, fileNameForType: UTType.png.identifier) == "Drawing.png")
        let url = FileManager.default.temporaryDirectory.appending(path: "promise-\(UUID().uuidString).png")
        let error: (any Error)? = await withCheckedContinuation { done in
            promise.filePromiseProvider(promise, writePromiseTo: url) { done.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: url) == png)
        // An unwritable destination reports the error to the drop target.
        let bad = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/Drawing.png")
        let failed: (any Error)? = await withCheckedContinuation { done in
            promise.filePromiseProvider(promise, writePromiseTo: bad) { done.resume(returning: $0) }
        }
        #expect(failed != nil)
    }
    #endif

    // MARK: Helpers

    final class Asked: @unchecked Sendable {
        var png = false
        var scene = false
    }

    private func load(_ provider: NSItemProvider, _ type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? DrawingTransfer.Failure.imageUnavailable) }
            }
        }
    }

    private func loadFile(_ provider: NSItemProvider, _ type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                // The file is only valid inside the handler.
                if let url, let data = try? Data(contentsOf: url) { done.resume(returning: data) } else {
                    done.resume(throwing: error ?? DrawingTransfer.Failure.imageUnavailable)
                }
            }
        }
    }
}
