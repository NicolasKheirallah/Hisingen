import AppKit
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
                               title: L10n.text("Battery Health & Longevity"), color: .green)
                    KVRow(L10n.text("Calculated State of Health (SoH)"),
                          L10n.text("Waiting for 100% charge"), symbol: "clock")
                    Text(L10n.text("Charge the vehicle to 100% to create the first SoH estimate. Hisingen saves the vehicle-reported range at full charge, divides it by the configured WLTP range, and updates the saved value only after another 100% reading."))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(rangeModeGuidance)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        let statusColor: Color = soh >= 90.0 ? HisingenTheme.semanticGood : (soh >= 80.0 ? HisingenTheme.semanticWarning : .red)
        let history = asyncData.batteryHealthHistory

        return AnyView(Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "battery.100.bolt", title: L10n.text("Battery Health & Longevity"), color: .green)
                    Spacer()
                    Pill(
                        text: status,
                        color: statusColor,
                        symbol: "function"
                    )
                }

                VStack(spacing: 6) {
                    KVRow(L10n.text("Battery Pack"), packDesc, symbol: "cube.fill", info: L10n.text("Manufacturer Specification. Architecture, chemical composition, and gross capacity of the high-voltage battery."))

                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(HisingenTheme.accent)
                                .frame(width: 14)
                            Text(L10n.text("Calculated State of Health (SoH)"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            InformationButton(message: estimate.methodologySummary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            ProgressView(value: min(100, soh), total: 100)
                                .progressViewStyle(.linear)
                                .frame(width: 60)
                                .tint(statusColor)
                            Text(String(format: "%.1f%%", soh))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(statusColor)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("Calculated state of health"))
                    .accessibilityValue(String(format: "%.1f%%", soh))

                    Text(estimate.methodologySummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(rangeModeGuidance)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
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
                    KVRow(L10n.text("Calculated Degradation"), String(format: "%.1f%%", deg), symbol: "arrow.down.right.circle.fill", valueWarning: deg > 15.0, info: estimate.methodologySummary)
                    KVRow(L10n.text("Estimated Usable Capacity"), String(format: "%.1f kWh / %.1f kWh (%.1f kWh nominal)", usable, factoryUsable, nominal), symbol: "battery.100", info: L10n.text("Calculated from the displayed SoH estimate and configured reference capacity. It is not a measured BMS capacity."))
                    KVRow(L10n.text("Typical Warranty Reference"), L10n.text("70% / 160,000 km (8 Years)"), symbol: "shield.lefthalf.filled", info: L10n.text("General reference only. Warranty coverage varies by vehicle, market and in-service date; verify your vehicle documents."))

                    if !history.isEmpty {
                        Divider().opacity(0.4)
                            .padding(.vertical, 2)

                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(history.prefix(5)) { r in
                                    HStack {
                                        Text(Format.dateTimeFormatter.string(from: r.timestamp))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(String(format: "%.0f km", r.odometerKm))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "%.1f%% SoH", r.stateOfHealthPct))
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(HisingenTheme.semanticGood)
                                    }
                                    .padding(.vertical, 1)
                                    .help(r.measurementSource == BatteryHealthRecord.fullChargeRangeSource
                                        ? L10n.text("Saved full-charge range estimate. It updates only after another 100% reading.")
                                        : L10n.text("Previous calculation retained for trend continuity; it is not used as the current SoH."))
                                }
                                HStack {
                                    Spacer()
                                    Button {
                                        exportBatteryHealthCSV()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "square.and.arrow.up")
                                            Text(L10n.text("Export Health Log (CSV)"))
                                        }
                                        .font(.system(size: 10, weight: .medium))
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.mini)
                                }
                                .padding(.top, 2)
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack {
                                Text(L10n.text("Calculated SoH Milestones"))
                                Spacer()
                                Text(L10n.format("%d logs", history.count))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .disclosureGroupStyle(WholeRowDisclosureStyle())
                    }
                }
            }
        })
    }

    func exportBatteryHealthCSV() {
        let csv = database.history.exportBatteryHealthCSV(for: state.identity.vin)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "battery_health_\(state.identity.vin.prefix(8)).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            } catch {
                reportError = error.localizedDescription
            }
        }
    }
}
