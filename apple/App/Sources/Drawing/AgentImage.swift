import DesignSystem
import Foundation
import ImageIO
import PaneLayout
import SwiftUI
import UniformTypeIdentifiers
import GudoCore
#if os(iOS)
import PhotosUI
#endif

/// A picture the user hands an agent, written again from its pixels: upright, at most 2048 px
/// on its long side, and without its location, camera or time. Screenshots stay PNG, photos
/// become JPEG.
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
        let isScreenshot = CGImageSourceGetType(source) as String? == UTType.png.identifier
        let type = isScreenshot ? UTType.png : UTType.jpeg
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

    /// Prepares `data` off the main thread and attaches it to the agent's prompt on its host.
    static func send(_ data: Data, to destination: AgentDestination, window: WindowModel) async {
        let agent = destination.agent.title
        do {
            let image = try await Task.detached(priority: .userInitiated) { try AgentImage.prepare(data) }.value
            guard let daemon = window.app.hosts.connection(destination.hostId) as? DaemonConnection,
                  let client = daemon.workspace.api as? DaemonClient
            else { throw ArtifactError.Disconnected }
            _ = try await client.sendToAgent(paneId: destination.pane, artifactId: nil, version: nil, png: image)
            window.toasts.show(Toast("Image sent to \(agent)", systemImage: "photo", style: .success))
        } catch AgentImage.Failure.tooLarge {
            window.toasts.show(Toast("The image is too large to send", systemImage: "photo", style: .failure))
        } catch AgentImage.Failure.unreadable {
            window.toasts.show(Toast("That file is not an image", systemImage: "photo", style: .failure))
        } catch {
            CanvasWebView.log.error("image to agent: \(String(describing: error), privacy: .public)")
            window.toasts.show(Toast("\(agent) did not get it: \(DrawOverlay.describe(error))", systemImage: "photo", style: .failure))
        }
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
                    await AgentImageSender.send(data, to: destination, window: model)
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
                Task { await AgentImageSender.send(data, to: destination, window: model) }
            }
        #endif
    }
}

extension View {
    func agentImagePicker(_ model: WindowModel) -> some View { modifier(AgentImagePicker(model: model)) }
}
