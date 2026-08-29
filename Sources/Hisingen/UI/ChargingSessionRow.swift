import SwiftUI

struct ChargingSessionRow: View {
    let session: ChargingSession

    @State private var isHovered = false
    @Environment(\.preferencesStore) private var preferences

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !session.samples.isEmpty {
                    ChargingCurveView(
                        samples: session.samples,
                        targetPercentage: session.targetPercentage,
                        readyDate: nil,
                        isLive: false,
                        currentPowerWatts: nil,
                        energySource: session.energySource,
                        confidence: session.confidence,
                        sampleCoverage: session.sampleCoverage
                    )
                }
                VStack(spacing: 6) {
                    KVRow(L10n.text("Duration"), Format.shortDuration(minutes: session.durationMinutes), symbol: "timer")
                    KVRow(
                        L10n.text("Estimated Energy Added"),
                        String(format: "%.1f kWh", session.kwhDelivered),
                        symbol: "bolt.fill", info: energyExplanation
                    )
                    KVRow(
                        L10n.text("Estimate Quality"),
                        "\(session.confidence.displayName) · \(session.energySource.displayName)",
                        symbol: "checkmark.seal",
                        info: L10n.text("Shows whether energy came from sufficiently complete observed-power integration or from the SoC and usable-capacity fallback.")
                    )
                    if let peak = session.peakPowerWatts, peak > 0 {
                        KVRow(L10n.text("Peak Power"), Format.kilowatts(watts: peak), symbol: "waveform.path.ecg")
                    }
                    if let cost = session.estimatedCost(tariff: preferences.electricityPricePerKwh) {
                        KVRow(L10n.text("Estimated Cost"), String(format: "%.2f %@", cost, session.currencySymbol ?? preferences.currencySymbol), symbol: "creditcard")
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.dateTimeFormatter.string(from: session.startDate))
                        .font(.system(size: 11, weight: .medium))
                    let costStr = session.estimatedCost(tariff: preferences.electricityPricePerKwh).map { String(format: " · %.2f %@", $0, session.currencySymbol ?? preferences.currencySymbol) } ?? ""
                    Text(String(format: "+%.0f%% · ≈%.1f kWh%@", session.percentageAdded, session.kwhDelivered, costStr))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.samples.count >= 2 {
                    MiniSparklineView(samples: session.samples)
                }
            }
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        .font(.system(size: 11))
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .animation(Motion.selection, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var energyExplanation: String {
        switch session.energySource {
        case .observedPowerIntegration:
            return L10n.text("Integrated from sufficiently complete charging-power observations. SoC may move differently because vehicle percentages are rounded or reported late.")
        case .socCapacityEstimate:
            return L10n.text("Estimated from the change in battery percentage and configured usable capacity; not measured by the charger or battery-management system.")
        case .legacyEstimate:
            return L10n.text("Imported from an older Hisingen summary whose original calculation inputs were not retained.")
        }
    }
}
