#if os(iOS)
import CoreGraphics
import DesignSystem
import Foundation
import SwiftUI

/// Reads images the conversation names from the host, decoded no larger than they are shown,
/// and keeps the last few so scrolling back does not read them again.
@MainActor
final class ChatImageLoader {
    typealias Reader = (String) async throws -> Data

    var read: Reader?
    private let cache = BoundedLRU<String, CGImage>(capacity: 24, byteLimit: 48 << 20)

    init(read: Reader? = nil) { self.read = read }

    func cached(_ path: String) -> CGImage? { cache.value(for: path) }

    func image(_ path: String) async throws -> CGImage {
        if let image = cache.value(for: path) { return image }
        guard let read else { throw CancellationError() }
        let data = try await read(path)
        let image = try await Task.detached(priority: .userInitiated) {
            try ImageThumbnail.decode(data, maximumPixelSize: ChatImageBox.maximumPixelSize)
        }.value
        cache.insert(image, for: path, cost: LRUCost(bytes: image.bytesPerRow * image.height, units: 1))
        return image
    }
}

struct ChatInlineImage: View {
    let path: String
    let height: CGFloat
    let loader: ChatImageLoader?
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = image ?? loader?.cached(path) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: DS.Radius.pane, style: .continuous))
                    .overlay { RoundedRectangle.rounded(DS.Radius.pane).strokeBorder(DS.Palette.hairline) }
                    .accessibilityLabel(Text(verbatim: name))
            } else {
                Label {
                    Text(verbatim: name)
                        .lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                }
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Palette.sidebar, in: .rect(cornerRadius: DS.Radius.pane, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
        .frame(height: height)
        .task(id: path) {
            guard image == nil, let loader else { return }
            do { image = try await loader.image(path) } catch { failed = !(error is CancellationError) }
        }
    }

    private var name: String { (path as NSString).lastPathComponent }
}
#endif
