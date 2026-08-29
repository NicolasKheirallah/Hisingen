import AppKit
import SwiftUI

extension InfoTabView {
    // MARK: - Battery health

    var batteryHealthCard: some View {
        guard let estimate = batteryHealthEstimate else { return AnyView(EmptyView()) }

        let soh = estimate.stateOfHealthPercent
        let deg = estimate.degradationPercent
        let status = L10n.text("Calculated") + " · " + estimate.confidence.displayName
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

                    KVRow(L10n.text("Calculated Degradation"), String(format: "%.1f%%", deg), symbol: "arrow.down.right.circle.fill", valueWarning: deg > 15.0, info: estimate.methodologySummary)
                    KVRow(L10n.text("Estimated Usable Capacity"), String(format: "%.1f kWh / %.1f kWh (%.1f kWh nominal)", usable, factoryUsable, nominal), symbol: "battery.100", info: L10n.text("Calculated from the displayed SoH estimate and configured reference capacity. It is not a measured BMS capacity."))
                    KVRow(L10n.text("Typical Warranty Reference"), L10n.text("70% / 160,000 km (8 Years)"), symbol: "shield.lefthalf.filled", info: L10n.text("General reference only. Warranty coverage varies by vehicle, market and in-service date; verify your vehicle documents."))

                    DisclosureGroup(L10n.text("Calculation Signals")) {
                        VStack(spacing: 7) {
                            ForEach(estimate.signals) { signal in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(signal.title.capitalized)
                                            .font(.system(size: 10.5, weight: .semibold))
                                        Spacer()
                                        Text(String(format: "%.1f%% · %.0f%% weight", signal.estimatedSOHPercent, signal.weight * 100))
                                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(signal.explanation)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 11, weight: .medium))

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
                                    .help(r.measurementSource == "calculated-v2"
                                        ? L10n.text("Calculated estimate using Hisingen's current multi-signal method; not a BMS measurement.")
                                        : L10n.text("Legacy calculated estimate retained for trend continuity; not a BMS measurement."))
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
        let csv = database.exportBatteryHealthCSV(for: state.vin)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "battery_health_\(state.vin.prefix(8)).csv"
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
