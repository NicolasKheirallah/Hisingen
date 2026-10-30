import SwiftUI

/// The tinted fill and padding shared by the status-label family (``Pill``,
/// ``StateSummaryChip``, ``CommandReceiptChip``). Insets and wash are parameters because the
/// three chips were tuned separately and their pixels must not move.
@MainActor
struct StatusChipSurfaceModifier: ViewModifier {
    let tint: Color
    let wash: Double
    let horizontal: CGFloat
    let vertical: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(
                tint.opacity(wash),
                in: RoundedRectangle(cornerRadius: HisingenTheme.statusChipRadius, style: .continuous)
            )
    }
}

@MainActor
extension View {
    /// Pads the label and fills it with a tint wash on the status chip radius. The default
    /// wash and insets are ``Pill``'s; callers that differ pass their own.
    func statusChipSurface(
        tint: Color,
        wash: Double = 0.12,
        horizontal: CGFloat = 7,
        vertical: CGFloat = 2.5
    ) -> some View {
        modifier(StatusChipSurfaceModifier(tint: tint, wash: wash, horizontal: horizontal, vertical: vertical))
    }
}
