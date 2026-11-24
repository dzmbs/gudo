import HostKit

extension Pane {
    /// An input method is still composing text in the terminal.
    var isComposingText: Bool {
        #if canImport(UIKit)
        view.markedTextRange != nil
        #else
        view.hasMarkedText()
        #endif
    }

    func prepareToParkTerminal() -> Bool {
        guard !isComposingText, let sizing = backend as? any DeferredPaneSizing else { return false }
        let wasDeferred = sizing.isSizeDeferred
        sizing.deferSize()
        guard resignTerminalFocus() else {
            if !wasDeferred { sizing.cancelSizeDeferral() }
            return false
        }
        return true
    }

    private func resignTerminalFocus() -> Bool {
        #if canImport(UIKit)
        !view.isFirstResponder || view.resignFirstResponder()
        #else
        guard let window = view.window, window.firstResponder === view else { return true }
        return window.makeFirstResponder(nil)
        #endif
    }
}
