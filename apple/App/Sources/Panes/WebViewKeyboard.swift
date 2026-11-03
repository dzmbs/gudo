import WebKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Keyboard focus for pages shown in panes (VS Code, a drawing): taking it from a terminal sends
/// its software keyboard and key bar away, while hardware keys and the app's shortcuts keep a
/// responder in the window. The software keyboard comes back only when the page focuses a field.
extension WKWebView {
    var ownsKeyboard: Bool {
        #if os(macOS)
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
        #else
        firstResponderWithin() != nil
        #endif
    }

    /// Takes the keyboard once the page is in a window, which a pane just placed reaches a few
    /// turns later.
    func claimKeyboard() {
        Task { @MainActor [weak self] in
            for attempt in 0..<20 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(16)) }
                guard let self else { return }
                guard window != nil else { continue }
                guard !ownsKeyboard else { return }
                #if os(macOS)
                window?.makeFirstResponder(self)
                #else
                becomeFirstResponder()
                #endif
                return
            }
        }
    }

    func releaseKeyboard() {
        #if os(macOS)
        if ownsKeyboard { window?.makeFirstResponder(nil) }
        #else
        endEditing(true)
        _ = resignFirstResponder()
        #endif
    }
}

#if canImport(UIKit)
private extension UIView {
    func firstResponderWithin() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let found = subview.firstResponderWithin() { return found }
        }
        return nil
    }
}
#endif
