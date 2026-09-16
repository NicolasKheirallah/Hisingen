import SwiftUI

/// Shared chrome for the panel's dismissible notice banners (first-launch welcome,
/// retained-data notice): leading icon, combined title/detail/footnote text block, and a
/// plain xmark button with reduceMotion-aware dismissal animation and dismiss
/// accessibility built in. Callers own the dismissed state – the banner only reports the
/// tap through `onDismiss`.
@MainActor
struct DismissibleNoticeBanner: View {
    let icon: String
    let title: String
    let details: [String]
    var footnote: String?
    var tint: Color = HisingenTheme.accent
    /// Long-form explanation attached to the whole banner; nil leaves the banner unannotated.
    var containerHelp: String?
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A banner should read as a notice rather than as a card, so it takes the shared banner radius
    /// (`HisingenTheme.bannerRadius`, 10) instead of the card's 12. This used to be a second,
    /// independent value — `min(8, cornerRadius)` — while `ControlsBanners` drew its own banners at
    /// the token's 10, so the two notices in the same column had different curves. The `min(8, …)`
    /// also guarded against a sharp-cornered theme that no longer exists; `cornerRadius` is 12 for
    /// every theme.
    private var bannerRadius: CGFloat { HisingenTheme.bannerRadius }

    var body: some View {
        if let containerHelp {
            banner.help(containerHelp)
        } else {
            banner
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .hisType(.label, weight: .semibold)
                ForEach(details, id: \.self) { detail in
                    Text(detail)
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let footnote {
                    Text(footnote)
                        .hisType(.micro)
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                withAnimation(reduceMotion ? nil : Motion.cardChange) {
                    onDismiss()
                }
            } label: {
                // 32pt: a 9pt glyph in a 24pt box was 55% of a usable pointer target, and this
                // is the control reached for when a banner is in the way, i.e. aimed quickly.
                Image(systemName: "xmark")
                    .hisType(.caption, weight: .semibold)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(HisingenTheme.inkMuted)
            .accessibilityLabel(L10n.text("Dismiss"))
            .help(L10n.text("Dismiss"))
        }
        .padding(9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: bannerRadius))
        .overlay(RoundedRectangle(cornerRadius: bannerRadius).stroke(tint.opacity(0.22)))
        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.95)))
    }
}
