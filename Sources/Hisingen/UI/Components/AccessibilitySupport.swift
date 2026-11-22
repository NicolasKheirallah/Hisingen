import SwiftUI

extension View {
    /// Applies `accessibilityAdjustableAction` only when the control actually adjusts.
    ///
    /// The modifier itself makes VoiceOver announce a control as adjustable. Attaching it to
    /// every card would promise an increment/decrement gesture that does nothing, so the
    /// announcement stays tied to the cards that have a value to adjust.
    @ViewBuilder
    func accessibilityAdjustableActionIf(
        _ isAdjustable: Bool,
        _ action: @escaping (AccessibilityAdjustmentDirection) -> Void
    ) -> some View {
        if isAdjustable {
            accessibilityAdjustableAction(action)
        } else {
            self
        }
    }
}
