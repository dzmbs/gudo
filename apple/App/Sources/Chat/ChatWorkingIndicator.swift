#if os(iOS)
import DesignSystem
import HostKit
import SwiftUI

/// Three dots under the last row while the agent works. The working shimmer sweeps them;
/// under Reduce Motion they hold still.
struct ChatWorkingIndicator: View {
    private static let dots = "•••"

    var body: some View {
        Text(verbatim: Self.dots)
            .font(DS.Font.proseHeading)
            .foregroundStyle(DS.Palette.textSecondary)
            .shimmering(true, text: Self.dots)
            .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.xxs)
            .background(DS.Palette.raised, in: .capsule)
            .padding(.bottom, DS.Space.s)
            .allowsHitTesting(false)
            .accessibilityLabel("Working")
            .accessibilityIdentifier("chat-working")
    }
}

/// Reads a host image for Chat: a regular file no larger than an inline image may be.
enum ChatImageReader {
    enum Failure: Error { case notConnected, notAnImage, tooLarge }

    static func read(_ path: String, from hub: DaemonWorkspace) async throws -> Data {
        guard let api = hub.api else { throw Failure.notConnected }
        let stat = try await api.fsStat(path: path)
        guard stat.kind == .file else { throw Failure.notAnImage }
        guard stat.size <= ChatImageBox.maximumFileBytes else { throw Failure.tooLarge }
        var data = Data()
        while UInt64(data.count) < stat.size {
            let chunk = try await api.fsRead(path: path, offset: UInt64(data.count), len: 1 << 20)
            data.append(chunk.data)
            if chunk.eof || chunk.data.isEmpty { break }
        }
        return data
    }
}
#endif
