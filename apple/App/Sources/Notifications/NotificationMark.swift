import DesignSystem
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The program's mark on its tile, drawn in the chrome's colours to a PNG that a notification
/// shows beside its words.
@MainActor
enum NotificationMark {
    static let tileSide: CGFloat = 48

    /// A new file each time, since the system moves an attachment into its own store. Nil for a
    /// note without a program (a long command) or when drawing fails.
    static func write(program: String?, in directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("notification-marks", isDirectory: true)) -> URL? {
        guard let program, !program.isEmpty, let png = png(for: ProgramCatalog.identity(process: program)) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(UUID().uuidString).png")
            try png.write(to: file)
            return file
        } catch {
            return nil
        }
    }

    static func png(for identity: ProgramIdentity) -> Data? {
        let chrome = ChromePalette.fromPreferences()
        let tile = ProgramTile(identity, size: tileSide)
            .padding(DS.Space.m)
            .background(DS.Palette.raised, in: .rounded(DS.Radius.pane))
            .environment(\.chrome, chrome)
            .environment(\.colorScheme, chrome.scheme)
        let renderer = ImageRenderer(content: tile)
        renderer.scale = 3
        guard let image = renderer.cgImage else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }
}
