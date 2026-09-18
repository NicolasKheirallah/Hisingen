import SwiftUI

/// A charging session as the hero's headline, not a row: the car's own estimate of the
/// finish, the power arriving, and the energy added so far — each figure present only when
/// the car reports it, because a scene that invented numbers would be decoration wearing
/// telemetry.
///
/// The estimate leads at the display tier: it is the one number a reader plugged in at a
/// café actually came for. Power and delivered energy support it. The battery gauge with its
/// particle flow stays exactly where it was; this strip is the sentence above it. Completion
/// is acknowledged where it already was — the gauge pulse and the menu-bar glyph's settle —
/// because one moment should own the ending.
@MainActor
struct ChargingSessionScene: View {
    let state: VehicleState

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let minutes = state.energy.estimatedTimeToFullMinutes, minutes > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.format("Full in about %d min", minutes))
                        .hisType(.display, weight: HisingenTheme.displayWeight)
                        .tracking(HisingenTheme.displayTracking(forSize: 28))
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.ink)
                        .hisTelemetryValue(minutes, reduceMotion: reduceMotion)
                        .accessibilityLabel(L10n.format("Fully charged in about %d minutes", minutes))
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                if let watts = state.energy.powerWatts, watts > 0 {
                    Label {
                        Text(String(format: "%.1f kW", Double(watts) / 1_000))
                            .hisType(.label, weight: .medium)
                    } icon: {
                        Image(systemName: "bolt.fill")
                            .hisType(.caption)
                            .foregroundStyle(HisingenTheme.accent)
                    }
                }
                if let target = state.energy.targetPercentage {
                    Label {
                        Text(L10n.format("Target %d%%", target))
                            .hisType(.label, weight: .medium)
                    } icon: {
                        Image(systemName: "arrow.up.to.line")
                            .hisType(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(HisingenTheme.inkMuted)
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        }
        .accessibilityElement(children: .contain)
    }
}
