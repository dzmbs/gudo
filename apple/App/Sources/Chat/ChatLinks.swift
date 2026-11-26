import Foundation
import SwiftUI
import TerminalCore

/// Links in an agent's reply. The agent may have read a page or file written to make it link
/// somewhere else than its label says, so a tap goes through `LinkSafety` with the label as what
/// the user saw.
nonisolated extension ChatMarkdownBlock {
    func linkAction(for url: URL) -> LinkSafety.Action {
        let texts = [text] + list.map(\.text) + table.flatMap(\.self)
        var labels: [String] = []
        for text in texts {
            for (link, range) in text.runs[\.link] where link == url {
                labels.append(String(text[range].characters))
            }
        }
        guard !labels.isEmpty else { return .confirm }
        let actions = labels.map { LinkSafety.action(for: url, shown: $0) }
        if actions.contains(.refuse) { return .refuse }
        return actions.allSatisfy { $0 == .open } ? .open : .confirm
    }
}

extension ChatMarkdownBlock {
    var openLink: OpenURLAction {
        OpenURLAction { url in
            switch linkAction(for: url) {
            case .open:
                return .systemAction
            case .refuse:
                return .discarded
            case .confirm:
                PaneLinks.confirmOpen(url, from: nil, source: "The agent wrote this link.") { PaneLinks.openExternally(url) }
                return .handled
            }
        }
    }
}
