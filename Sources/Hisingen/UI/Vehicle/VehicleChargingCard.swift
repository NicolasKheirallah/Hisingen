import SwiftUI

@MainActor
struct VehicleChargingCard: View {
    let state: VehicleState
    let database: VehicleDatabase

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var persistentSessions: [ChargingSession] = []

    private var features: FeatureSelection { preferences.features }
    private var loadIdentifier: String {
        "\(state.identity.vin)|\(state.freshness.fetchedAt.timeIntervalSinceReferenceDate)"
    }
    private var eligible: Bool {
        (state.powertrain.hasElectricRange || state.isCharging || state.energy.connection != .disconnected)
            && (features.contains(.chargingDetails) || features.contains(.batteryDiagnostics))
    }

    var body: some View {
        Group {
            if eligible && state.powertrain.hasElectricRange && hasContent {
                card
            } else if eligible && state.powertrain.hasElectricRange {
                // The card was simply not built when it had nothing to show, so a charging section
                // that failed to load was indistinguishable from a vehicle that has no charging
                // section at all. The Doors and Location cards explain themselves in this position.
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardHeader(symbol: "bolt.fill", title: L10n.text("Charging"), color: HisingenTheme.semanticGood, isSemantic: true)
                        HisingenEmptyState(
                            symbol: "questionmark.circle",
                            title: L10n.text("Temporarily unavailable"),
                            message: L10n.text("No charging telemetry has been reported for this vehicle yet.")
                        )
                    }
                }
            }
        }
        .task(id: loadIdentifier) { await loadPersistentSessions() }
    }

    private var headline: String? {
        guard features.contains(.chargingDetails) else { return nil }
        if state.isCharging {
            var parts = [state.energy.chargingState.displayName]
            if let watts = state.energy.powerWatts, watts > 0 { parts.append(Format.kilowatts(watts: watts)) }
            if state.energy.type != .unknown, state.energy.type != .none { parts.append(state.energy.type.displayName) }
            return parts.joined(separator: " · ")
        }
        switch state.energy.connection {
        case .connected: return L10n.text("Connected · Not charging")
        case .fault: return L10n.text("Charger fault")
        case .disconnected: return L10n.text("Not connected")
        case .unknown: return nil
        }
    }

    private var readyLine: String? {
        guard state.isCharging, let completion = state.formattedCompletionTime,
              let minutes = state.remainingChargingMinutes, minutes > 0 else { return nil }
        // Marked as an estimate in the line itself. It sits one weight step below the measured
        // headline and the card already calls this a "Vehicle Dynamic Calculation" in its
        // detail rows, but at a glance it read as a reading.
        return state.chargingEstimateDestination + " · " + L10n.format("Est. ready %@ · about %@", completion, Format.shortDuration(minutes: minutes))
    }

    private var secondaryLine: String? {
        guard state.isCharging else { return nil }
        var parts: [String] = []
        if let rate = state.formattedChargingRate(unit: preferences.distanceUnit) { parts.append(rate) }
        if let battery = state.energy.batteryPercentage, let target = state.energy.targetPercentage, battery < Double(target) {
            let capacity = preferences.vehicleSpecificationOverride(for: state.identity.vin)?.usableBatteryCapacityKwh ?? state.factoryUsableBatteryCapacityKwh
            let cost = ((Double(target) - battery) / 100) * capacity * preferences.electricityPricePerKwh
            if cost > 0 {
                // Whole units: the inputs are an assumed usable capacity and a static price, so
                // hundredths implied precision the calculation does not have. The basis is
                // stated because every detail row below this line names its own.
                parts.append(L10n.format("≈%@ to target at your %@/kWh setting",
                                          Format.currency(cost.rounded(), symbol: preferences.currencySymbol),
                                          String(format: "%.2f", preferences.electricityPricePerKwh)))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var details: [KVRow] {
        taggedDetails.enumerated().sorted { lhs, rhs in
            let left = preferences.chargingStatOrder.firstIndex(of: lhs.element.id) ?? .max
            let right = preferences.chargingStatOrder.firstIndex(of: rhs.element.id) ?? .max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element.row)
    }

    private var taggedDetails: [(id: String, row: KVRow)] {
        var rows: [(String, KVRow)] = []
        if features.contains(.chargingDetails) {
            if state.energy.connection != .unknown { rows.append(("connection", KVRow(L10n.text("Charger Connection"), state.energy.connection.displayName, symbol: "powerplug.fill", valueWarning: state.energy.connection == .fault))) }
            if state.energy.type != .unknown, state.energy.type != .none { rows.append(("type", KVRow(L10n.text("Charging Type"), state.energy.type.displayName, symbol: "bolt.circle"))) }
            if let amps = state.energy.currentAmps, amps > 0 { rows.append(("draw", KVRow(L10n.text("Current Draw"), "\(amps) A", symbol: "waveform.path.ecg", info: L10n.text("Live Telematics. Active AC or DC current drawn from the EVSE charger.")))) }
            if let amps = state.energy.currentLimitAmps, amps > 0 { rows.append(("limit", KVRow(L10n.text("Current Limit"), "\(amps) A", symbol: "gauge.with.dots.needle.bottom.100percent", info: L10n.text("User Setting. Max AC charging current limit configured in vehicle charging settings.")))) }
            if let volts = state.energy.voltageVolts, volts > 0 { rows.append(("voltage", KVRow(L10n.text("Voltage"), "\(volts) V", symbol: "bolt.fill", info: L10n.text("Live Telematics. Active AC input voltage or DC bus voltage measured by onboard charger.")))) }
            if let target = state.energy.targetPercentage { rows.append(("target", KVRow(L10n.text("Target Limit"), "\(target)%", symbol: "target", info: L10n.text("User Setting. Selected high-voltage battery charge limit target.")))) }
        }
        if features.contains(.batteryDiagnostics), let diagnostics = state.energy.diagnostics {
            if diagnostics.chargerPowerState != .unknown { rows.append(("powerModule", KVRow(L10n.text("Power Module"), diagnostics.chargerPowerState.displayName, symbol: "batteryblock", valueWarning: diagnostics.chargerPowerState == .fault))) }
            if let minutes = diagnostics.timeToTargetMinutes { rows.append(("timeToTarget", KVRow(L10n.text("Time to Target"), Format.shortDuration(minutes: minutes), symbol: "timer", info: L10n.text("Vehicle Dynamic Calculation. Estimated time remaining until the high-voltage battery reaches the configured charge target.")))) }
            if let minutes = diagnostics.timeToMinimumSOCMinutes { rows.append(("timeToMinSoc", KVRow(L10n.text("Time to Min SOC"), Format.shortDuration(minutes: minutes), symbol: "battery.50percent", info: L10n.text("Vehicle Dynamic Calculation. Estimated time to reach minimum operating state of charge.")))) }
            if let value = diagnostics.averageConsumption { rows.append(("avgConsumption", KVRow(L10n.text("Avg Consumption"), Format.energyConsumption(kwhPer100Km: value, unit: preferences.energyConsumptionUnit), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Lifetime or long-term average energy consumption from trip computer.")))) }
            if let value = diagnostics.averageConsumptionSinceCharge { rows.append(("avgSinceCharge", KVRow(L10n.text("Avg Since Last Charge"), Format.energyConsumption(kwhPer100Km: value, unit: preferences.energyConsumptionUnit), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Average electric consumption recorded since the vehicle was last unplugged.")))) }
            if let value = diagnostics.averageConsumptionAutomatic { rows.append(("avgAutoTrip", KVRow(L10n.text("Avg (Automatic Trip)"), Format.energyConsumption(kwhPer100Km: value, unit: preferences.energyConsumptionUnit), symbol: "chart.line.uptrend.xyaxis", info: L10n.text("Vehicle Calculation. Average electric consumption over the automatic trip-meter period.")))) }
            if let wattHours = diagnostics.energyUsedSinceChargeWh { rows.append(("energySinceCharge", KVRow(L10n.text("Energy Since Charge"), String(format: "%.1f kWh", wattHours / 1_000), symbol: "leaf.fill", info: L10n.text("Vehicle Calculation. Total high-voltage energy consumed by powertrain and HVAC since the last charge.")))) }
            if let powerLimit = diagnostics.powerLimitKw, powerLimit > 0 {
                rows.append(("powerLimit", KVRow(L10n.text("Power Limit"), String(format: "%.0f kW", powerLimit), symbol: "gauge.with.needle", info: L10n.text("Instantaneous drivetrain output power ceiling."))))
            }
            if let breakdown = diagnostics.energyBreakdown, breakdown.hasData {
                if let drive = breakdown.driving {
                    rows.append(("energyDrive", KVRow(L10n.text("Traction Energy"), formatBreakdown(drive), symbol: "car.fill", info: L10n.text("Energy consumed directly by electric drivetrain motors."))))
                }
                if let climate = breakdown.climate {
                    rows.append(("energyClimate", KVRow(L10n.text("Climate Energy"), formatBreakdown(climate), symbol: "fan.fill", info: L10n.text("Energy consumed by cabin heating and air conditioning."))))
                }
                if let battery = breakdown.battery {
                    rows.append(("energyBattery", KVRow(L10n.text("Battery Thermal"), formatBreakdown(battery), symbol: "flame.fill", info: L10n.text("Energy consumed by high-voltage battery thermal conditioning and warming."))))
                }
                if let other = breakdown.other {
                    rows.append(("energyOther", KVRow(L10n.text("Electronics & Aux"), formatBreakdown(other), symbol: "cpu", info: L10n.text("Energy consumed by 12 V computers, lighting, and auxiliary electronics."))))
                }
            }
        }
        return rows
    }

    private func formatBreakdown(_ item: EnergyBreakdownItem) -> String {
        var parts: [String] = []
        if let wh = item.wattHours {
            parts.append(String(format: "%.1f kWh", wh / 1_000.0))
        }
        if let pct = item.percentage {
            parts.append(String(format: "%.0f%%", pct))
        }
        guard !parts.isEmpty else { return "—" }
        return parts.count > 1 ? "\(parts[0]) (\(parts[1]))" : parts[0]
    }

    private var activeSamples: [ChargingSample] {
        if !state.energy.samples.isEmpty { return state.energy.samples }
        if state.isCharging, let percentage = state.energy.batteryPercentage {
            // The single point a charge starts with is stamped with the *vehicle's* report time,
            // not Hisingen's fetch time, and marked as the estimate it is: the chart drew it like an
            // observed sample, so a reading the car took twenty minutes ago appeared to have been
            // measured when the app last polled.
            let reportedAt = state.freshness.vehicleReportedAt ?? state.freshness.fetchedAt
            return [ChargingSample(timestamp: reportedAt, batteryPercentage: percentage,
                                   powerWatts: state.energy.powerWatts, isSynthesised: true)]
        }
        return []
    }

    private var hasContent: Bool { headline != nil || !details.isEmpty || !activeSamples.isEmpty || !persistentSessions.isEmpty }

    private var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    CardHeader(symbol: "bolt.fill", title: L10n.text("Charging"), color: HisingenTheme.semanticGood, isSemantic: true, isPulsing: state.isCharging)
                    if state.isComplete { Image(systemName: "checkmark.circle.fill").hisType(.heading, weight: .semibold).foregroundStyle(HisingenTheme.semanticGood).transition(.scale(scale: 0.86).combined(with: .opacity)).accessibilityLabel(L10n.text("Complete")) }
                }
                // Tabular figures on all three stacked lines. Every one of them carries a number
                // that changes as the car charges, and a proportional face re-lays-out the string
                // on every digit that changes width, so the whole card reflowed across its full
                // width on each refresh. The app had five explicit tabular sites against 24 inline
                // live-value labels with none.
                // No `.id(...)` on the formatted string. It destroyed and rebuilt each line on
                // every refresh, so the countdown flickered instead of morphing and could not be
                // interrupted mid-update. `hisTelemetryValue` rolls the digits in place.
                if let headline { Text(headline).hisType(.title, weight: .semibold).monospacedDigit().foregroundStyle(state.isCharging ? HisingenTheme.semanticGood : .primary).hisTelemetryValue(headline, reduceMotion: reduceMotion) }
                if let readyLine { Text(readyLine).hisType(.body, weight: .medium).monospacedDigit().foregroundStyle(.secondary).hisTelemetryValue(readyLine, reduceMotion: reduceMotion) }
                if let secondaryLine { Text(secondaryLine).hisType(.label).monospacedDigit().foregroundStyle(.tertiary).hisTelemetryValue(secondaryLine, reduceMotion: reduceMotion) }
                if !activeSamples.isEmpty { ChargingCurveView(samples: activeSamples, targetPercentage: state.energy.targetPercentage, readyDate: state.estimatedChargingCompletion, isLive: state.isCharging && !state.hasOldData(), currentPowerWatts: state.energy.powerWatts).transition(.opacity) }
                if !details.isEmpty {
                    Text(state.chargingExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L10n.text("Charging Details")) { VStack(spacing: 6) { ForEach(details.indices, id: \.self) { details[$0] } }.padding(.top, 6) }.disclosureGroupStyle(WholeRowDisclosureStyle()).hisType(.body, weight: .medium)
                }
                if !persistentSessions.isEmpty { history }
            }
            .animation(reduceMotion ? nil : Motion.cardChange, value: "\(headline ?? "")|\(readyLine ?? "")|\(secondaryLine ?? "")|\(activeSamples.count)|\(state.isComplete)")
        }
    }

    private var history: some View {
        DisclosureGroup {
            VStack(spacing: 8) {
                ForEach(persistentSessions.reversed(), id: \.id) { ChargingSessionRow(session: $0) }
                Divider().opacity(HisingenTheme.dividerOpacity)
                HStack {
                    Spacer()
                    Menu {
                        Button(L10n.text("Export as CSV...")) { ChargingHistoryExport.saveCSV(sessions: persistentSessions, vin: state.identity.vin, tariffPricePerKwh: preferences.electricityPricePerKwh, currencySymbol: preferences.currencySymbol) }
                        Button(L10n.text("Export as JSON...")) { ChargingHistoryExport.saveJSON(sessions: persistentSessions, vin: state.identity.vin) }
                    } label: { HStack(spacing: 4) { Image(systemName: "square.and.arrow.up"); Text(L10n.text("Export")) }.hisType(.caption, weight: .medium) }
                    .menuStyle(.borderlessButton).controlSize(.mini)
                }
            }.padding(.top, 6)
        } label: {
            HStack { Text(L10n.text("Charging History")); Spacer(); Text(L10n.format("%d sessions", persistentSessions.count)).hisType(.caption).foregroundStyle(.secondary) }
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle()).hisType(.body, weight: .medium)
    }

    private func loadPersistentSessions() async {
        guard eligible else { persistentSessions = []; return }
        let database = database
        let vin = state.identity.vin
        let capacity = state.configuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: vin)).kwh
        let sessions = await Task.detached(priority: .userInitiated) {
            database.charging.recentChargingSessions(for: vin).map { database.charging.domainSession(from: $0, usableCapacityKwh: capacity) }.filter { $0.percentageAdded > 0 && $0.kwhDelivered > 0 }
        }.value
        guard !Task.isCancelled else { return }
        persistentSessions = sessions
    }
}
