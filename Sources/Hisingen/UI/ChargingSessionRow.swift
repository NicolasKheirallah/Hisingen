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
                        currentPowerWatts: session.peakPowerWatts
                    )
                }
                VStack(spacing: 6) {
                    KVRow(L10n.text("Duration"), Format.shortDuration(minutes: session.durationMinutes), symbol: "timer")
                    KVRow(L10n.text("Estimated Energy Added"), String(format: "%.1f kWh", session.kwhDelivered), symbol: "bolt.fill", info: L10n.text("Estimated from the change in battery percentage and configured usable capacity; not measured by the charger or battery-management system."))
                    if let peak = session.peakPowerWatts, peak > 0 {
                        KVRow(L10n.text("Peak Power"), Format.kilowatts(watts: peak), symbol: "waveform.path.ecg")
                    }
                    if let cost = session.estimatedCost(tariff: preferences.electricityPricePerKwh) {
                        KVRow(L10n.text("Estimated Cost"), String(format: "%.2f %@", cost, preferences.currencySymbol), symbol: "creditcard")
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.dateTimeFormatter.string(from: session.startDate))
                        .font(.system(size: 11, weight: .medium))
                    let costStr = session.estimatedCost(tariff: preferences.electricityPricePerKwh).map { String(format: " · %.2f %@", $0, preferences.currencySymbol) } ?? ""
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
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
