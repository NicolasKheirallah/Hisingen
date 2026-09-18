import SwiftUI

/// The pull-to-refresh affordance at the panel's top edge: a small chip that grows with the
/// pull, arms at the threshold, and collapses once released.
///
/// The chip travels with the pull 1:1 in its scale and displacement — feedback during the
/// gesture, not a verdict at its end — and the armed state (accent ring, flipped arrow) is
/// what the release actually commits. Ongoing-refresh feedback stays with the footer's
/// rotating glyph, the one place refresh state already lives; this chip owns only the pull.
@MainActor
struct PullToRefreshOverlay: View {
    /// Rubber-banded distance the reader has pulled, in points.
    let pullDistance: CGFloat
    /// Distance at which a release commits.
    let threshold: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: CGFloat {
        min(1, max(0, pullDistance / threshold))
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down")
                .hisType(.caption, weight: .semibold)
                .rotationEffect(.degrees(progress >= 1 ? 180 : 0))
            Text(progress >= 1 ? L10n.text("Release to refresh") : L10n.text("Pull to refresh"))
                .hisType(.caption, weight: .medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // The status-label radius, not a capsule: this chip reports state ("pull", "release"),
        // and the house rule is that nothing is pill-shaped by default.
        .background(HisingenTheme.chipFill, in: RoundedRectangle(cornerRadius: HisingenTheme.statusChipRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HisingenTheme.statusChipRadius, style: .continuous)
                .stroke(
                    progress >= 1 ? HisingenTheme.accent.opacity(0.55) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
        }
        .foregroundStyle(progress >= 1 ? HisingenTheme.accent : HisingenTheme.inkMuted)
        .contentTransition(reduceMotion ? .identity : .opacity)
        .shadow(color: HisingenTheme.shadowTint(0.10), radius: 4, y: 2)
        .opacity(pullDistance > 1 ? 1 : 0)
        .scaleEffect(0.8 + 0.2 * progress)
        .offset(y: -6 + 10 * progress)
        .frame(maxWidth: .infinity)
        .hisAnimation(reduceMotion ? nil : Motion.interaction, value: progress >= 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progress >= 1 ? L10n.text("Release to refresh") : L10n.text("Pull to refresh"))
        .accessibilityHidden(true)
    }
}
