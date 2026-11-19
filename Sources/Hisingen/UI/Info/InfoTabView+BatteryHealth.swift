import SwiftUI

extension InfoTabView {
    // MARK: - Battery health

    var batteryHealthCard: some View {
        let rangeModeGuidance = L10n.text(
            "For the closest estimate, set the car's range display to Standard, not Dynamic."
        )
        guard let estimate = batteryHealthEstimate else {
            return AnyView(Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "battery.100.bolt",
                               title: L10n.text("Battery Health & Longevity"), color: HisingenTheme.semanticGood)
                    KVRow(L10n.text("Calculated State of Health (SoH)"),
                          L10n.text("Waiting for 100% charge"), symbol: "clock")
                    Text(L10n.text("Charge the vehicle to 100% to create the first SoH estimate. Hisingen saves the vehicle-reported range at full charge, divides it by the configured WLTP range, and updates the saved value only after another 100% reading."))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(rangeModeGuidance)
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)
                    batteryLinks
                }
            })
        }

        let soh = estimate.stateOfHealthPercent
        let deg = estimate.degradationPercent
        let status = estimate.isRemembered
            ? L10n.text("Saved at 100% charge")
            : L10n.text("Updated at 100% charge")
        let usable = estimate.estimatedUsableCapacityKwh
        let factoryUsable = estimate.referenceUsableCapacityKwh
        let nominal = state.factoryNominalBatteryCapacityKwh
        let packDesc = state.batteryPackDescription
        let statusColor: Color = soh >= 90.0 ? HisingenTheme.semanticGood : (soh >= 80.0 ? HisingenTheme.semanticWarning : HisingenTheme.semanticCritical)

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "battery.100.bolt", title: L10n.text("Battery Health & Longevity"), color: HisingenTheme.semanticGood)
                    Spacer()
                    Pill(
                        text: status,
                        color: statusColor,
                        symbol: "function"
                    )
                }

                VStack(spacing: 6) {
                    KVRow(L10n.text("Battery Pack"), packDesc, symbol: "cube", info: L10n.text("Manufacturer Specification. Architecture, chemical composition, and gross capacity of the high-voltage battery."))

                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "heart")
                                .hisType(.label)
                                .foregroundStyle(HisingenTheme.accent)
                                .frame(width: 14)
                            Text(L10n.text("Calculated State of Health (SoH)"))
                                .hisType(.label, weight: .medium)
                                .foregroundStyle(.secondary)
                            InformationButton(message: estimate.methodologySummary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            ProgressView(value: min(100, soh), total: 100)
                                .progressViewStyle(.linear)
                                .frame(width: 60)
                                .tint(statusColor)
                                .hisAnimation(Motion.progress, value: soh)
                            Text(String(format: "%.1f%%", locale: L10n.displayLocale, soh))
                                .hisType(.label, weight: .bold)
                                .foregroundStyle(statusColor)
                                .hisTelemetryValue(soh, reduceMotion: reduceMotion)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("Calculated state of health"))
                    .accessibilityValue(String(format: "%.1f%%", locale: L10n.displayLocale, soh))

                    Text(estimate.methodologySummary)
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)

                    Text(rangeModeGuidance)
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(.secondary)
                        .hisCaptionLeading()
                        .fixedSize(horizontal: false, vertical: true)

                    if let fullChargeRange = estimate.fullChargeRangeKm,
                       let wltpReference = estimate.wltpReferenceRangeKm {
                        KVRow(L10n.text("Range at 100% charge"),
                              Format.distance(km: fullChargeRange, unit: preferences.distanceUnit),
                              symbol: "gauge.with.needle")
                        KVRow(L10n.text("WLTP range used"),
                              Format.distance(km: wltpReference, unit: preferences.distanceUnit),
                              symbol: "road.lanes")
                    }
                    KVRow(L10n.text("Last 100% calculation"),
                          Format.dateTimeFormatter.string(from: estimate.recordedAt),
                          symbol: "clock")
                    KVRow(L10n.text("Calculated Degradation"), String(format: "%.1f%%", locale: L10n.displayLocale, deg), symbol: "arrow.down.right.circle", valueWarning: deg > 15.0, info: estimate.methodologySummary)
                    KVRow(L10n.text("Estimated Usable Capacity"), String(format: "%.1f kWh / %.1f kWh (%.1f kWh nominal)", locale: L10n.displayLocale, usable, factoryUsable, nominal), symbol: "battery.100", info: L10n.text("Calculated from the displayed SoH estimate and configured reference capacity. It is not a measured BMS capacity."))
                    KVRow(L10n.text("Typical Warranty Reference"), L10n.text("70% / 160,000 km (8 Years)"), symbol: "shield.lefthalf.filled", info: L10n.text("General reference only. Warranty coverage varies by vehicle, market and in-service date; verify your vehicle documents."))

                    batteryLinks
                }
            }
        })
    }

    private var batteryLinks: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let onNavigateToSettings {
                NavigationRow(title: L10n.text("Edit Vehicle References")) { onNavigateToSettings(.vehicleReferences) }
            }
            if let onNavigateToLogSection, !asyncData.batteryHealthHistory.isEmpty {
                NavigationRow(title: L10n.text("Open Battery Health History")) {
                    onNavigateToLogSection(.historyBatteryHealth)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
