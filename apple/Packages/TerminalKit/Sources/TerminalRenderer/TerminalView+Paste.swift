import Foundation
import UniformTypeIdentifiers

extension TerminalView {
    /// File URLs become shell-escaped paths; ordinary URLs keep their textual representation.
    public func pasteURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pasteText(urls.map { $0.isFileURL ? Self.shellQuoted($0.path) : $0.absoluteString }.joined(separator: " "))
    }

    static func shellQuoted(_ path: String) -> String {
        let plain = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+,:@%".contains($0) }
        return plain ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What pasting `providers` types: files as shell-escaped paths, text as it is, other links
    /// as their address, several items joined by spaces; nil when there is nothing to type.
    static func pastedText(from providers: [NSItemProvider]) async -> String? {
        var pieces: [String] = []
        for provider in providers {
            if let piece = await pastedText(from: provider), !piece.isEmpty { pieces.append(piece) }
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " ")
    }

    private static func pastedText(from provider: NSItemProvider) async -> String? {
        // A file also reads as text (its URL string): its path is what a shell wants.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(from: provider), url.isFileURL
        {
            return shellQuoted(url.path)
        }
        if provider.canLoadObject(ofClass: NSString.self) {
            return await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in done.resume(returning: object as? String) }
            }
        }
        if provider.canLoadObject(ofClass: NSURL.self), let url = await loadURL(from: provider) {
            return url.isFileURL ? shellQuoted(url.path) : url.absoluteString
        }
        return nil
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in done.resume(returning: (object as? NSURL) as URL?) }
        }
    }
}
