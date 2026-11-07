import TerminalCore

extension TerminalView {
    func consumeEscape(_ key: KeyEvent) -> Bool {
        guard key.key == .escape else { return false }
        if case .release = key.action {
            let consumed = consumedEscape
            consumedEscape = false
            return consumed
        }
        guard key.mods.isEmpty else { return false }
        switch key.action {
        case .press:
            consumedEscape = onEscape?() ?? false
            return consumedEscape
        case .repeat: return consumedEscape
        case .release: return false
        }
    }
}
