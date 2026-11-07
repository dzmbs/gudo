#if canImport(UIKit)
import UIKit

extension UIView {
    func firstResponderWithin() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.firstResponderWithin() { return responder }
        }
        return nil
    }
}
#endif
