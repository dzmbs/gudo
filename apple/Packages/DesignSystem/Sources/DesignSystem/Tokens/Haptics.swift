import SwiftUI

public extension DS {
    /// The only haptics the app plays. Each maps a meaning to one `SensoryFeedback` so the same event
    /// always feels the same; none fire for pointer or hardware-keyboard input.
    enum Haptic {
        /// Tab or pane selection changed by touch.
        public static let select = SensoryFeedback.selection
        /// A split was created, closed, or a divider snapped.
        public static let structure = SensoryFeedback.impact(weight: .light)
        /// Approve sent, host paired.
        public static let success = SensoryFeedback.success
        /// An agent became blocked while visible, deny sent.
        public static let attention = SensoryFeedback.warning
        /// A connection failed.
        public static let failure = SensoryFeedback.error
        /// A full swipe armed: letting go now runs the action (Mail's tick).
        public static let armed = SensoryFeedback.impact(flexibility: .rigid, intensity: 0.6)
    }
}
