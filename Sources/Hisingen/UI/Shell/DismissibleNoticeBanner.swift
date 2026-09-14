import SwiftUI

/// Shared chrome for the panel's dismissible notice banners (first-launch welcome,
/// retained-data notice): leading icon, combined title/detail/footnote text block, and a
/// plain xmark button with reduceMotion-aware dismissal animation and dismiss
/// accessibility built in. Callers own the dismissed state — the banner only reports the
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
                    .font(.system(size: 11, weight: .semibold))
                ForEach(details, id: \.self) { detail in
                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let footnote {
                    Text(footnote)
                        .font(.system(size: 9))
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
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(HisingenTheme.inkMuted)
            .accessibilityLabel(L10n.text("Dismiss"))
            .help(L10n.text("Dismiss"))
        }
        .padding(9)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.22)))
        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.95)))
    }
}
