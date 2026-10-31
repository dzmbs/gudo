import DesignSystem
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension WindowModel {
    /// A new fold from the probe. Opening into a book, standing it up as a laptop or laying it
    /// flat reflows in one animation; the same tab, panes, drafts and scrollback stay on screen.
    func updateFold(_ next: FoldGeometry) {
        guard next != fold else { return }
        if FoldLayout.plan(next) == FoldLayout.plan(fold) {
            fold = next
        } else {
            withAnimation(Self.reduceMotion ? nil : DS.Motion.fold) { fold = next }
        }
        syncColumns()
    }

    private static var reduceMotion: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #else
        false
        #endif
    }
}
