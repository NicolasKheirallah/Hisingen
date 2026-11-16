import SwiftUI

struct ChargingSessionRow: View {
    let session: ChargingSession

    @State private var isHovered = false
    @State private var isExpanded = false
    @Environment(\.preferencesStore) private var preferences
    @Environment(\.scrollRevealAction) private var revealInScrollView

    private var scrollID: String { "charging-session-\(session.id.uuidString)" }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
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
                    if let wallbox = wallboxPresentation {
                        KVRow(L10n.text("Charger Energy"), wallbox.energyValue, symbol: "powerplug", info: wallbox.energyInfo)
                    }
                    if showsBatteryEstimate {
                        KVRow(
                            L10n.text("Estimated Energy Added"),
                            String(format: "%.1f kWh", locale: L10n.displayLocale, session.kwhDelivered),
                            symbol: "bolt", info: energyExplanation
                        )
                    }
                    if session.hasBatteryReading, session.wallbox != nil {
                        KVRow(L10n.text("Battery"), "\(Format.percent(session.startBatteryPercentage)) → \(Format.percent(session.endBatteryPercentage))",
                              symbol: "battery.50percent")
                    }
                    if let wallbox = wallboxPresentation, let costValue = wallbox.costValue {
                        KVRow(wallbox.costLabel, costValue, symbol: "creditcard", info: wallbox.costInfo)
                    }
                    if session.samples.isEmpty, showsBatteryEstimate {
                        KVRow(
                            L10n.text("Estimate Quality"),
                            "\(session.confidence.displayName) · \(session.energySource.displayName)",
                            symbol: "checkmark.seal",
                            info: L10n.text("Shows whether energy came from sufficiently complete observed-power integration or from the SoC and usable-capacity fallback.")
                        )
                    }
                    if let peak = session.peakPowerWatts, peak > 0 {
                        KVRow(L10n.text("Peak Power"), Format.kilowatts(watts: peak), symbol: "waveform.path.ecg")
                    }
                    if session.wallbox?.cost == nil, showsBatteryEstimate,
                       let cost = session.resolvedCost(policy: preferences.electricityRatePolicy, fallbackPricePerKwh: preferences.electricityPricePerKwh) {
                        KVRow(L10n.text("Estimated Cost"), String(format: "%.2f %@", locale: L10n.displayLocale, cost, session.currencySymbol ?? preferences.currencySymbol), symbol: "creditcard")
                    }
                    if let spotCost = session.spotCost, spotCost > 0 {
                        KVRow(
                            L10n.text("Market Price Cost"),
                            String(format: "%.2f %@", locale: L10n.displayLocale, spotCost, session.currencySymbol ?? preferences.currencySymbol),
                            symbol: "chart.bar",
                            info: L10n.text("Charged at the actual spot price for each interval. Spot prices exclude taxes and grid fees, so this is lower than a full bill.")
                        )
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.dateTimeFormatter.string(from: session.startDate))
                        .hisType(.label, weight: .medium)
                    let ratePolicy = preferences.electricityRatePolicy
                    let preferredCost = ratePolicy.isAutomatic
                        ? session.resolvedCost(policy: ratePolicy, fallbackPricePerKwh: preferences.electricityPricePerKwh)
                        : session.spotCost ?? session.estimatedCost(tariff: preferences.electricityPricePerKwh)
                    let costStr = preferredCost.map { String(format: " · %.2f %@", locale: L10n.displayLocale, $0, session.currencySymbol ?? preferences.currencySymbol) } ?? ""
                    Text(summaryLine(costStr: costStr))
                        .hisType(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.samples.count >= 2 {
                    MiniSparklineView(samples: session.samples)
                }
            }
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        .hisType(.label)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 0, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .hisAnimation(Motion.selection, value: isHovered)
        .contextMenu {
            Button {
                var details = """
                    \(Format.dateTimeFormatter.string(from: session.startDate))
                    \(Format.energyKwh(session.wallbox?.energyKwh ?? session.kwhDelivered)) · \(Format.shortDuration(minutes: session.durationMinutes))
                    """
                if session.hasBatteryReading {
                    details += "\n\(Format.percent(session.startBatteryPercentage)) → \(Format.percent(session.endBatteryPercentage))"
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(details, forType: .string)
            } label: {
                Label(L10n.text("Copy"), systemImage: "doc.on.doc")
            }
        }
        .onHover { isHovered = $0 }
        .id(scrollID)
        .onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard isExpanded else { return }
                revealInScrollView(scrollID)
            }
        }
    }

    private var wallboxPresentation: WallboxSessionPresentation? {
        session.wallbox.map { WallboxSessionPresentation($0, currencyFallback: session.currencySymbol ?? preferences.currencySymbol) }
    }

    /// A session the charger recorded with no battery reading has no battery-side estimate to show.
    private var showsBatteryEstimate: Bool {
        session.wallbox == nil || session.hasBatteryReading || session.kwhDelivered > 0
    }

    /// Charger energy leads when a charger measured the session; the battery figure follows as the estimate it is.
    private func summaryLine(costStr: String) -> String {
        guard let wallbox = session.wallbox else {
            return String(format: "+%.0f%% · ≈%.1f kWh%@", locale: L10n.displayLocale, session.percentageAdded, session.kwhDelivered, costStr)
        }
        var parts = [L10n.format("%@ from charger", Format.energyKwh(wallbox.energyKwh))]
        if session.hasBatteryReading {
            parts.append(String(format: "+%.0f%%", locale: L10n.displayLocale, session.percentageAdded))
        }
        if let cost = wallbox.cost {
            parts.append(Format.currency(cost, symbol: wallbox.currency ?? session.currencySymbol ?? preferences.currencySymbol))
        }
        return parts.joined(separator: " · ")
    }

    private var energyExplanation: String {
        switch session.energySource {
        case .observedPowerIntegration:
            return L10n.text("Integrated from sufficiently complete charging-power observations. SoC may move differently because vehicle percentages are rounded or reported late.")
        case .socCapacityEstimate:
            return L10n.text("Estimated from the change in battery percentage and configured usable capacity; not measured by the charger or battery-management system.")
        case .legacyEstimate:
            return L10n.text("Imported from an older Hisingen summary whose original calculation inputs were not retained.")
        case .wallboxOnly:
            return L10n.text("The charger recorded this session while no battery reading was available, so there is no battery-side estimate.")
        }
    }
}
