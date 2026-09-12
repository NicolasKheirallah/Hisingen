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
        return state.chargingEstimateDestination + " · " + L10n.format("Ready at %@ · %@ remaining", completion, Format.shortDuration(minutes: minutes))
    }

    private var secondaryLine: String? {
        guard state.isCharging else { return nil }
        var parts: [String] = []
        if let rate = state.formattedChargingRate(unit: preferences.distanceUnit) { parts.append(rate) }
        if let battery = state.energy.batteryPercentage, let target = state.energy.targetPercentage, battery < Double(target) {
            let capacity = preferences.vehicleSpecificationOverride(for: state.identity.vin)?.usableBatteryCapacityKwh ?? state.factoryUsableBatteryCapacityKwh
            let cost = ((Double(target) - battery) / 100) * capacity * preferences.electricityPricePerKwh
            if cost > 0 { parts.append("≈" + String(format: "%.2f %@", cost, preferences.currencySymbol) + " " + L10n.text("to target")) }
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
        }
        return rows
    }

    private var activeSamples: [ChargingSample] {
        if !state.energy.samples.isEmpty { return state.energy.samples }
        if state.isCharging, let percentage = state.energy.batteryPercentage {
            return [ChargingSample(timestamp: state.freshness.fetchedAt, batteryPercentage: percentage, powerWatts: state.energy.powerWatts)]
        }
        return []
    }

    private var hasContent: Bool { headline != nil || !details.isEmpty || !activeSamples.isEmpty || !persistentSessions.isEmpty }

    private var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    CardHeader(symbol: "bolt.fill", title: L10n.text("Charging"), color: .green, isSemantic: true, isPulsing: state.isCharging)
                    if state.isComplete { Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(HisingenTheme.semanticGood).transition(.scale(scale: 0.86).combined(with: .opacity)).accessibilityLabel(L10n.text("Complete")) }
                }
                if let headline { Text(headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(state.isCharging ? HisingenTheme.semanticGood : .primary).id(headline).transition(.opacity) }
                if let readyLine { Text(readyLine).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).id(readyLine).transition(.opacity) }
                if let secondaryLine { Text(secondaryLine).font(.system(size: 11)).foregroundStyle(.tertiary).id(secondaryLine).transition(.opacity) }
                if !activeSamples.isEmpty { ChargingCurveView(samples: activeSamples, targetPercentage: state.energy.targetPercentage, readyDate: state.estimatedChargingCompletion, isLive: state.isCharging, currentPowerWatts: state.energy.powerWatts).transition(.opacity) }
                if !details.isEmpty {
                    Text(state.chargingExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup(L10n.text("Charging Details")) { VStack(spacing: 6) { ForEach(details.indices, id: \.self) { details[$0] } }.padding(.top, 6) }.disclosureGroupStyle(WholeRowDisclosureStyle()).font(.system(size: 12, weight: .medium))
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
                Divider().opacity(0.4)
                HStack {
                    Spacer()
                    Menu {
                        Button(L10n.text("Export as CSV...")) { ChargingHistoryExport.saveCSV(sessions: persistentSessions, vin: state.identity.vin, tariffPricePerKwh: preferences.electricityPricePerKwh, currencySymbol: preferences.currencySymbol) }
                        Button(L10n.text("Export as JSON...")) { ChargingHistoryExport.saveJSON(sessions: persistentSessions, vin: state.identity.vin) }
                    } label: { HStack(spacing: 4) { Image(systemName: "square.and.arrow.up"); Text(L10n.text("Export")) }.font(.system(size: 10, weight: .medium)) }
                    .menuStyle(.borderlessButton).controlSize(.mini).withoutFocusRing()
                }
            }.padding(.top, 6)
        } label: {
            HStack { Text(L10n.text("Charging History")); Spacer(); Text(L10n.format("%d sessions", persistentSessions.count)).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .disclosureGroupStyle(WholeRowDisclosureStyle()).font(.system(size: 12, weight: .medium))
    }

    private func loadPersistentSessions() async {
        guard eligible else { persistentSessions = []; return }
        let database = database
        let vin = state.identity.vin
        let capacity = preferences.vehicleSpecificationOverride(for: vin)?.usableBatteryCapacityKwh ?? state.configuredUsableBatteryCapacityKwh
        let sessions = await Task.detached(priority: .userInitiated) {
            database.charging.recentChargingSessions(for: vin).map { database.charging.domainSession(from: $0, usableCapacityKwh: capacity) }.filter { $0.percentageAdded > 0 && $0.kwhDelivered > 0 }
        }.value
        guard !Task.isCancelled else { return }
        persistentSessions = sessions
    }
}
