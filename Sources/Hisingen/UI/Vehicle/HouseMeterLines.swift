import SwiftUI

/// The house meter's part of the home charger section: what the whole house draws, and while the
/// car charges, how that splits between the car and the rest. Nothing draws until a Perific meter is
/// connected and has answered once, so a reader without one sees the section unchanged.
///
/// Design read: muted label lines under the phase line, as the charger's own readings are. The
/// house figure is context for the session figure above it, so it takes no accent and no size. A
/// reading that is no longer current stays visible, in the same muted ink, with its age beneath.
@MainActor
struct HouseMeterLines: View {
    @ObservedObject var meter: HouseMeterModel
    /// The charger's own power, only when it is current. The split needs both readings to be live.
    let carKw: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if meter.isConnected {
            let lines = meter.presentation(carKw: carKw)
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
    }
}
