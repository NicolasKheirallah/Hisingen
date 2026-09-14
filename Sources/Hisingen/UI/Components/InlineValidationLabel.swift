import SwiftUI

/// Shared inline validation / error message label for settings forms.
/// Single source of truth so font, color and accessibility stay in sync.
/// Callers must set the presenting state inside a `withAnimation` (or bind an
/// `.animation`) for the entrance to play — the transition is declared here so
/// every form gets the same slide-fade without repeating it per site.
struct InlineValidationLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.red)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityLabel(message)
    }
}
