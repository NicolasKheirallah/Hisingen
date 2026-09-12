import SwiftUI

@MainActor
struct VehicleDiagnosticsCard: View {
    let state: VehicleState
    let features: FeatureSelection
    let preferences: PreferencesStore

    static func make(state: VehicleState, features: FeatureSelection, preferences: PreferencesStore) -> AnyView? {
        let card = Self(state: state, features: features, preferences: preferences)
        if card.rows.isEmpty {
            guard !state.isVolvo else { return nil }
            return UnavailableFeatureCard.make(state: state, feature: nil, symbol: "stethoscope", title: L10n.text("Diagnostics & Sensors"), color: .orange, badge: L10n.text("Sensor readings"))
        }
        return AnyView(card)
    }

    private var rows: [KVRow] {
        var rows: [KVRow] = []
        if state.powertrain.hasElectricRange && (features.contains(.batteryDiagnostics) || features.contains(.chargingDetails)) {
            let specification = preferences.vehicleSpecificationOverride(for: state.identity.vin)
            if let comparison = state.currentRangeVsModelWltpPercent(specification: specification) {
                rows.append(KVRow(L10n.text("Current Range vs Model WLTP"), String(format: "%.1f%%", comparison), symbol: "gauge.with.dots.needle.67percent", info: specification?.wltpRangeKm != nil
                    ? L10n.text("Calculated from the vehicle-reported range and battery percentage against the VIN-specific WLTP reference entered in Settings. It is not battery health and does not directly measure speed, weather or climate use.")
                    : L10n.text("Calculated from the vehicle-reported range and battery percentage against a static model-family WLTP benchmark. It is not battery health and does not directly measure speed, weather or climate use.")))
            }
        }
        if features.contains(.connectivityDiagnostics), let connectivity = state.connectivity {
            rows.append(KVRow(L10n.text("Vehicle Network"), connectivity.state.displayName, symbol: "antenna.radiowaves.left.and.right", valueWarning: connectivity.state == .disconnected))
            if let network = connectivity.networkType { rows.append(KVRow(L10n.text("Network Type"), L10n.text(network), symbol: "network")) }
            if let strength = connectivity.signalStrength {
                let bars = connectivity.signalBars.map { " (\($0)/4)" } ?? ""
                rows.append(KVRow(L10n.text("Signal Strength"), "\(L10n.text(strength))\(bars)", symbol: "cellularbars"))
            }
            if let reason = connectivity.wakeReason { rows.append(KVRow(L10n.text("Modem Wake Reason"), reason, symbol: "bolt.badge.clock")) }
            if let updated = connectivity.updatedAt { rows.append(KVRow(L10n.text("Modem Synced"), Format.dateTimeFormatter.string(from: updated), symbol: "clock.arrow.circlepath")) }
        }
        if let speed = state.tripComputer.averageSpeedKmH { rows.append(KVRow(L10n.text("Average Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit), symbol: "speedometer")) }
        if let consumption = state.fuelSystem.averageConsumptionLPer100Km { rows.append(KVRow(L10n.text("Avg Fuel Consumption"), Format.fuelEconomy(lPer100Km: consumption, unit: preferences.fuelEconomyUnit), symbol: "chart.line.uptrend.xyaxis")) }
        if let range = state.tripComputer.electricRangeKm { rows.append(KVRow(L10n.text("Trip Computer EV Range"), Format.distance(km: range, unit: preferences.distanceUnit), symbol: "gauge.with.needle", info: L10n.text("Vehicle Dynamic Estimate. Real-time driving range estimated by the onboard computer based on recent driving speed, elevation profile, and climate consumption."))) }
        if let hours = state.maintenance.service.engineHoursToService { rows.append(KVRow(L10n.text("Engine Hours to Service"), "\(hours) hrs", symbol: "timer")) }
        return rows
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "stethoscope", title: L10n.text("Diagnostics & Sensors"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }
}
