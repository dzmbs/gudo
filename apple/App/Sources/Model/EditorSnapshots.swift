import CryptoKit
import Foundation
import PaneLayout

/// The workbench's last picture per host and folder, kept across launches.
nonisolated struct EditorSnapshots: Sendable {
    let directory: URL

    static let shared = EditorSnapshots(
        directory: URL.cachesDirectory.appending(path: "editor-snapshots", directoryHint: .isDirectory))

    func load(for member: EditorMember) -> Data? {
        try? Data(contentsOf: file(for: member))
    }

    func save(_ picture: Data, for member: EditorMember) async {
        let file = file(for: member)
        let directory = directory
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? picture.write(to: file, options: .atomic)
        }.value
    }

    private func file(for member: EditorMember) -> URL {
        let digest = SHA256.hash(data: Data("\(member.hostId)|\(member.folder)".utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).jpg")
    }
}
