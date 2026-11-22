import SwiftUI

/// The house's part of the home charger section: what the whole house draws, and while the car
/// charges, how that splits between the car and the rest. A Perific meter draws it when one is
/// connected, and Tibber's live stream draws the same lines when the home has a Pulse (or Watty)
/// reader and no meter is chosen. Nothing draws until one of them has answered.
///
/// Design read: muted label lines under the phase line, as the charger's own readings are. The
/// house figure is context for the session figure above it, so it takes no accent and no size. A
/// reading that is no longer current stays visible, in the same muted ink, with its age beneath.
@MainActor
struct HouseMeterLines: View {
    @ObservedObject var meter: HouseMeterModel
    /// Tibber's live stream, which carries the production line a grid meter cannot see even when
    /// the Perific meter draws the house lines.
    @ObservedObject var tibber: TibberLiveModel
    /// The charger's own power, only when it is current. The split needs both readings to be live.
    let carKw: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if meter.isConnected {
            meterLines
        } else {
            liveLines(tibber.presentation(carKw: carKw))
        }
    }

    @ViewBuilder
    private var meterLines: some View {
        let lines = meter.presentation(carKw: carKw)
        let production = tibber.presentation(carKw: nil).productionLine
        VStack(alignment: .leading, spacing: 8) {
            if let house = lines.houseLine {
                Text(house)
                    .hisType(.label)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .hisTelemetryValue(house, reduceMotion: reduceMotion)
                if let split = lines.splitLine {
                    Text(split)
                        .hisType(.label)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .hisTelemetryValue(split, reduceMotion: reduceMotion)
                }
                // The HAN port sees only the grid connection, so production can only come from Tibber.
                if let production {
                    Text(production)
                        .hisType(.label)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .hisTelemetryValue(production, reduceMotion: reduceMotion)
                }
                if let freshness = lines.freshnessLine {
                    Text(freshness)
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                if !lines.details.isEmpty {
                    DisclosureGroup(L10n.text("House Meter")) {
                        VStack(spacing: 6) {
                            ForEach(lines.details) { detail in
                                KVRow(detail.label, detail.value, info: detail.info)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .disclosureGroupStyle(WholeRowDisclosureStyle())
                    .hisType(.body, weight: .medium)
                }
            } else if case .unauthorized = meter.link {
                Text(L10n.text("Perific did not accept the saved login. Sign in again in Settings, Electricity."))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Tibber's lines, drawn exactly as the meter's are when no Perific meter is chosen.
    @ViewBuilder
    private func liveLines(_ lines: TibberLivePresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let house = lines.houseLine {
                Text(house)
                    .hisType(.label)
                    .monospacedDigit()
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .hisTelemetryValue(house, reduceMotion: reduceMotion)
                if let split = lines.splitLine {
                    Text(split)
                        .hisType(.label)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .hisTelemetryValue(split, reduceMotion: reduceMotion)
                }
                if let production = lines.productionLine {
                    Text(production)
                        .hisType(.label)
                        .monospacedDigit()
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .hisTelemetryValue(production, reduceMotion: reduceMotion)
                }
                if let freshness = lines.freshnessLine {
                    Text(freshness)
                        .hisType(.micro)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
