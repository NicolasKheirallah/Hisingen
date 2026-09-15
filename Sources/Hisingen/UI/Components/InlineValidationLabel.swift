import SwiftUI

/// Shared inline validation / error message label for settings forms.
/// Single source of truth so font, color and accessibility stay in sync.
/// Callers must set the presenting state inside a `withAnimation` (or bind an
/// `.animation`) for the entrance to play – the transition is declared here so
/// every form gets the same slide-fade without repeating it per site.
struct InlineValidationLabel: View {
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .hisType(.micro, weight: .medium)
            .foregroundStyle(.red)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel(message)
            // macOS has no live-region modifier (the typecheck confirms
            // `accessibilityLiveRegion` is unavailable here), so an appearing message announces
            // itself. Without this a VoiceOver user who mistypes gets no signal at all that the
            // field became invalid.
            .onAppear { AccessibilityNotification.Announcement(message).post() }
    }
}
