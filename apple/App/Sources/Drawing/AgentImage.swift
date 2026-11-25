import DesignSystem
import Foundation
import ImageIO
import PaneLayout
import SwiftUI
import TerminalRenderer
import UniformTypeIdentifiers
import GudoCore
#if os(iOS)
import PhotosUI
#endif

/// A picture the user hands an agent, written again from its pixels: upright, at most 2048 px
/// on its long side, and without its location, camera or time. Photos (JPEG, HEIC) become JPEG;
/// screenshots and graphics (PNG, TIFF, GIF, WebP) become PNG, keeping their transparency.
nonisolated enum AgentImage {
    static let maximumInputBytes = 40 * 1_024 * 1_024
    static let maximumBytes = 16 * 1_024 * 1_024
    static let maximumPixels = 2_048

    enum Failure: Error, Equatable { case unreadable, tooLarge }

    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= maximumInputBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { throw Failure.unreadable }
        let isPhoto = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
            .map { [UTType.jpeg, .heic, .heif].contains(where: $0.conforms(to:)) } ?? false
        let type = isPhoto ? UTType.jpeg : UTType.png
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        guard encoded.length <= maximumBytes else { throw Failure.tooLarge }
        return encoded as Data
    }
}

@MainActor
enum AgentImageSender {
    /// The agent `pane` runs on `workspace`'s host; nil for other panes, panes of this device
    /// and sessions the user only watches.
    static func destination(pane: PaneId, in workspace: Workspace, window: WindowModel) -> AgentDestination? {
        guard let daemon = workspace.daemon, workspace.multiplayer?.isViewOnly != true,
              let meta = daemon.meta[pane], let agent = meta.agent, meta.exit == nil
        else { return nil }
        let tab = daemon.layout.session.tabs.first { $0.root.panes.contains(pane) }
        return AgentDestination(
            hostId: workspace.groupId,
            hostName: window.groups.groups.first { $0.id == workspace.groupId }?.name ?? "",
            pane: pane.rawValue, agent: AgentKind(agent.kind), title: tab?.title ?? meta.title, sameHost: false)
    }

    /// At most this many pictures go with one paste or drop.
    static let maximumPerPaste = 8

    /// Prepares the pictures off the main thread and puts them in the agent's input on its host,
    /// in order, without sending the prompt.
    static func send(_ pictures: [Data], to destination: AgentDestination, window: WindowModel) async {
        guard let daemon = window.app.hosts.connection(destination.hostId) as? DaemonConnection,
              let client = daemon.workspace.api as? DaemonClient
        else {
            window.toasts.show(Toast("\(destination.agent.title) did not get it: disconnected", systemImage: "photo", style: .failure))
            return
        }
        window.toasts.show(await deliver(pictures, to: destination, through: client))
    }

    /// The host takes each picture into the pane's image store and pastes its path into the
    /// agent's input; a helper without that keeps the picture as an image of the session and
    /// pastes the same way.
    static func deliver(_ pictures: [Data], to destination: AgentDestination, through host: any AgentImageHost) async -> Toast {
        let agent = destination.agent.title
        guard pictures.count <= maximumPerPaste else {
            return Toast("Paste at most \(maximumPerPaste) images at once", systemImage: "photo", style: .failure)
        }
        do {
            let images = try await Task.detached(priority: .userInitiated) { try pictures.map(AgentImage.prepare) }.value
            let pastesImages = host.pastesImages()
            for image in images {
                if pastesImages {
                    try await host.pasteImage(pane: destination.pane, image: image)
                } else {
                    try await host.sendImage(pane: destination.pane, image: image)
                }
            }
            let what = images.count == 1 ? "Image" : "\(images.count) images"
            return Toast("\(what) sent to \(agent)", systemImage: "photo", style: .success)
        } catch AgentImage.Failure.tooLarge {
            return Toast("The image is too large to send", systemImage: "photo", style: .failure)
        } catch AgentImage.Failure.unreadable {
            return Toast("That file is not an image", systemImage: "photo", style: .failure)
        } catch {
            CanvasWebView.log.error("image to agent: \(String(describing: error), privacy: .public)")
            return Toast("\(agent) did not get it: \(describe(error))", systemImage: "photo", style: .failure)
        }
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? WorkspaceError else { return DrawOverlay.describe(error) }
        switch error {
        case .Denied: return "view only"
        case .Disconnected: return "disconnected"
        case .NotFound(let message), .Conflict(let message), .Invalid(let message), .Unavailable(let message), .Failed(let message):
            return message
        }
    }

    /// Sends what is pasted or dropped on `view` as pictures to the agent `destination` names,
    /// when it names one; otherwise the terminal pastes as before.
    static func install(
        on view: TerminalView,
        destination: @escaping @MainActor () -> AgentDestination?,
        send: @escaping @MainActor ([PastedImage], AgentDestination) -> Void
    ) {
        view.acceptsImages = { destination() != nil }
        view.onImages = { images in
            guard let target = destination() else { return }
            send(images, target)
        }
    }

    /// Reads the pictures (files off the main thread) and sends them.
    static func paste(_ images: [PastedImage], to destination: AgentDestination, window: WindowModel) {
        Task {
            let pictures = await Task.detached(priority: .userInitiated) {
                images.map { image -> Data in
                    switch image {
                    case .data(let data): data
                    case .file(let url): (try? Data(contentsOf: url)) ?? Data()
                    }
                }
            }.value
            await send(pictures, to: destination, window: window)
        }
    }
}

/// What a host's helper offers for handing an agent pictures.
nonisolated protocol AgentImageHost: Sendable {
    /// Whether the helper keeps pasted pictures per pane (`paste_image`).
    func pastesImages() -> Bool
    func pasteImage(pane: UInt64, image: Data) async throws
    /// Send to agent: the picture becomes an image of the session.
    func sendImage(pane: UInt64, image: Data) async throws
}

extension DaemonClient: AgentImageHost {
    nonisolated func pastesImages() -> Bool { offersPaneImages() }

    nonisolated func pasteImage(pane: UInt64, image: Data) async throws {
        _ = try await pasteImage(paneId: pane, image: image)
    }

    nonisolated func sendImage(pane: UInt64, image: Data) async throws {
        _ = try await sendToAgent(paneId: pane, artifactId: nil, version: nil, png: image)
    }
}

/// Asks for a picture when "Send Image to Agent…" was picked (`WindowModel.agentImageDestination`):
/// the photo library on iPhone and iPad, a file on the Mac.
struct AgentImagePicker: ViewModifier {
    @Bindable var model: WindowModel
    /// Kept apart from the window's request, which the picker clears as it closes, before
    /// the picked image arrives.
    @State private var destination: AgentDestination?
    #if os(iOS)
    @State private var item: PhotosPickerItem?
    #endif

    private var isPresented: Binding<Bool> {
        Binding(get: { model.agentImageDestination != nil }, set: { if !$0 { model.agentImageDestination = nil } })
    }

    func body(content: Content) -> some View {
        picker(content)
            .onChange(of: model.agentImageDestination) { _, requested in
                if let requested { destination = requested }
            }
    }

    @ViewBuilder private func picker(_ content: Content) -> some View {
        #if os(iOS)
        content
            .photosPicker(isPresented: isPresented, selection: $item, matching: .images, preferredItemEncoding: .current)
            .onChange(of: item) { _, picked in
                guard let picked, let destination else { return }
                item = nil
                self.destination = nil
                Task {
                    guard let data = try? await picked.loadTransferable(type: Data.self) else {
                        model.toasts.show(Toast("That file is not an image", systemImage: "photo", style: .failure))
                        return
                    }
                    await AgentImageSender.send([data], to: destination, window: model)
                }
            }
        #else
        content
            .fileImporter(isPresented: isPresented, allowedContentTypes: [.image]) { result in
                guard let destination else { return }
                self.destination = nil
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    model.toasts.show(Toast("That file is not an image", systemImage: "photo", style: .failure))
                    return
                }
                Task { await AgentImageSender.send([data], to: destination, window: model) }
            }
        #endif
    }
}

extension View {
    func agentImagePicker(_ model: WindowModel) -> some View { modifier(AgentImagePicker(model: model)) }
}
