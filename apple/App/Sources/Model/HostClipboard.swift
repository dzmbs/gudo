import DesignSystem
import Foundation
import HostKit
import PaneLayout
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension AppModel {
    /// OSC 52 from a host, as Ghostty does it: a program in a pane this device typed into last
    /// (vim's `y`, tmux's copy mode, also over ssh) copied text. The daemon sends it to that
    /// device only and never forwards a read.
    func clipboardWrite(_ hostId: String, _ pane: PaneId, _ text: String) {
        guard !text.isEmpty, text.utf8.count <= HostClipboard.maxBytes else { return }
        HostClipboard.copy(text)
        let title = (hosts.connection(hostId) as? DaemonConnection)?.meta[pane]?.title
        let source = HostClipboard.sourceName(paneTitle: title, hostName: hosts.record(hostId)?.name)
        window(forHost: hostId)?.toasts.show(Toast("Copied from \(source)", systemImage: "doc.on.clipboard", style: .neutral))
    }
}

/// The device's clipboard as programs on a host write it.
enum HostClipboard {
    /// The daemon's limit (`proto::MAX_CLIPBOARD_BYTES`).
    static let maxBytes = 1 << 20

    /// Puts `text` on this device's clipboard only: never to the user's other devices through
    /// Universal Clipboard, since a host's program chose it.
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        #else
        copy(text, to: .general)
        #endif
    }

    #if os(macOS)
    static func copy(_ text: String, to board: NSPasteboard) {
        board.prepareForNewContents(with: .currentHostOnly)
        board.setString(text, forType: .string)
    }
    #endif

    /// "vim", else the host: what the toast names.
    static func sourceName(paneTitle: String?, hostName: String?) -> String {
        if let title = paneTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title.count > 40 ? String(title.prefix(39)) + "…" : title
        }
        return hostName.map { "a pane on \($0)" } ?? "a pane"
    }
}
