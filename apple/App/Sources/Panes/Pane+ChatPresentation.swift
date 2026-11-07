#if os(iOS)
import HostKit

extension Pane {
    func prepareToParkTerminal() -> Bool {
        guard view.markedTextRange == nil, let sizing = backend as? any DeferredPaneSizing else { return false }
        let wasDeferred = sizing.isSizeDeferred
        sizing.deferSize()
        guard !view.isFirstResponder || view.resignFirstResponder() else {
            if !wasDeferred { sizing.cancelSizeDeferral() }
            return false
        }
        return true
    }
}
#endif
