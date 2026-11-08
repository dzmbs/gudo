#if os(iOS)
import GudoCore
import HostKit
import ImageIO
import PaneLayout
import UIKit
import XCTest
@testable import App

@MainActor
final class ChatPhotosTests: XCTestCase {
    private var suite = ""
    private var preferences: UserDefaults?

    override func setUp() async throws {
        suite = "chat-photo-tests-" + UUID().uuidString
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws { preferences?.removePersistentDomain(forName: suite) }

    func testImagePreparationBoundsDimensionsAndReleasesTheOwnedTemporaryFile() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let source = sourceDirectory.appending(path: "input.png")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 1_000), format: format)
            .pngData { context in context.cgContext.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_000)) }
        try image.write(to: source)
        let output = try await preparedAndReleased(source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testUploadAppendsAnEscapedReferencePreservesConcurrentTypingAndNeverSends() async throws {
        let state = try state(), file = try file()
        defer { state.deactivate() }
        var pending: CheckedContinuation<String, Never>?
        state.draft = "Original"
        state.photos.begin(in: state)
        state.photos.load(in: state, photo: { file }, source: { _ in
            await withCheckedContinuation { pending = $0 }
        })
        try await wait { pending != nil }
        XCTAssertEqual(state.photos.phase, .uploading)
        XCTAssertEqual(state.draft, "Original")
        state.draft = "Edited while uploading"
        pending?.resume(returning: "/fixture/Downloads/Gudo-Attachments/photo one.jpg")
        try await wait { state.photos.phase == .idle }
        XCTAssertEqual(state.draft, "Edited while uploading\n@/fixture/Downloads/Gudo-Attachments/photo\\ one.jpg")
        XCTAssertEqual(state.composer.phase, .idle)
        XCTAssertEqual(state.interrupt.phase, .idle)
    }

    func testCancellationAndPresentationRoundTripDiscardLateUploadCompletion() async throws {
        let state = try state(), file = try file()
        defer { state.deactivate() }
        var pending: CheckedContinuation<String, Never>?
        state.draft = "Retain this"
        state.photos.begin(in: state)
        state.photos.load(in: state, photo: { file }, source: { _ in await withCheckedContinuation { pending = $0 } })
        try await wait { pending != nil }
        XCTAssertTrue(state.select(.terminal, preparing: { true }))
        XCTAssertTrue(state.select(.chat, preparing: { true }))
        pending?.resume(returning: "/fixture/photo.jpg")
        await Task.yield()
        XCTAssertEqual(state.draft, "Retain this")
        XCTAssertEqual(state.photos.phase, .idle)
        XCTAssertNil(state.photos.message)
    }

    func testFullDraftKeepsTheUploadedReferenceForExplicitAdditionWithoutReuploading() async throws {
        let state = try state(), file = try file()
        defer { state.deactivate() }
        var uploads = 0
        state.draft = String(repeating: "a", count: ChatComposer.maximumDraftBytes)
        state.photos.begin(in: state)
        state.photos.load(in: state, photo: { file }, source: { _ in uploads += 1; return "/fixture/photo.jpg" })
        try await wait { state.photos.phase == .ready }
        XCTAssertEqual(state.draft.utf8.count, ChatComposer.maximumDraftBytes)
        state.draft = "Shorter"
        XCTAssertTrue(state.photos.append(to: state))
        XCTAssertFalse(state.photos.append(to: state))
        XCTAssertEqual(state.draft, "Shorter\n@/fixture/photo.jpg")
        XCTAssertEqual(uploads, 1)
    }

    func testReferencesRefuseRelativeOversizeAndControlBearingPaths() throws {
        for path in ["relative.jpg", "/photo\nnew prompt", "/photo\u{0}", "/" + String(repeating: "a", count: 8_192)] {
            XCTAssertThrowsError(try ChatPhotos.reference(path))
        }
        XCTAssertEqual(try ChatPhotos.reference("/photo's image.jpg"), "@/photo\\'s\\ image.jpg")
    }

    private func preparedAndReleased(_ source: URL) async throws -> URL {
        let file = try await Task.detached { try ChatPhotoFile.prepare(source) }.value
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(file.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2_048)
        XCTAssertLessThanOrEqual(file.bytes, ChatPhotoFile.maximumUploadBytes)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        return file.url
    }

    private func state() throws -> PaneChatState {
        PaneChatState(member: HostPane(hostId: "fixture", pane: PaneId(7)), defaultPresentation: .chat,
                      agent: .claude, preferences: try XCTUnwrap(preferences), pool: ChatModelPool())
    }
    private func file() throws -> ChatPhotoFile {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "photo.jpg")
        try Data([1]).write(to: url)
        return ChatPhotoFile(url: url, bytes: 1)
    }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Photo condition did not arrive", file: file, line: line)
    }
}
#endif
