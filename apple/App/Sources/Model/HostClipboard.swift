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
    /// OSC 52 from a host. The daemon sends it only to the device that typed into the pane last
    /// and never forwards a read.
    func clipboardWrite(_ hostId: String, _ pane: PaneId, _ text: String) {
        guard !text.isEmpty, text.utf8.count <= HostClipboard.maxBytes else { return }
        HostClipboard.copy(text)
        let title = (hosts.connection(hostId) as? DaemonConnection)?.meta[pane]?.title
        let source = HostClipboard.sourceName(paneTitle: title, hostName: hosts.record(hostId)?.name)
        window(forHost: hostId)?.toasts.show(Toast("Copied from \(source)", systemImage: "doc.on.clipboard", style: .neutral))
    }
}

enum HostClipboard {
    /// `proto::MAX_CLIPBOARD_BYTES`.
    static let maxBytes = 1 << 20

    /// Local only, never Universal Clipboard: a host's program chose the text.
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        #else
        copy(text, to: .general)
        #endif
    }

    #if os(macOS)
    static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
    }
    #endif

    /// The pane title ("vim"), else the host.
    static func sourceName(paneTitle: String?, hostName: String?) -> String {
        if let title = paneTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return title.count > 40 ? String(title.prefix(39)) + "…" : title
        }
        return hostName.map { "a pane on \($0)" } ?? "a pane"
    }
}
