import SwiftUI

@MainActor
struct FuelAndEngineCard: View {
    let state: VehicleState
    let preferences: PreferencesStore

    static func make(state: VehicleState, preferences: PreferencesStore) -> AnyView? {
        let card = Self(state: state, preferences: preferences)
        guard !card.rows.isEmpty else { return nil }
        return AnyView(card)
    }

    private var rows: [KVRow] {
        guard state.powertrain.hasFuelRange || state.fuelSystem.rangeKm != nil
                || state.fuelSystem.levelPercent != nil || state.fuelSystem.amountLiters != nil
                || state.fuelSystem.isEngineRunning != nil else { return [] }
        var rows: [KVRow] = []
        if let pct = state.fuelSystem.levelPercent {
            let liters = state.fuelSystem.amountLiters.map { " (\(Format.fuelVolume(liters: $0, unit: preferences.fuelVolumeUnit)))" } ?? ""
            rows.append(KVRow(L10n.text("Fuel Level"), String(format: "%.0f%%%@", pct, liters), symbol: "fuelpump.fill", valueWarning: pct <= 12))
        } else if let liters = state.fuelSystem.amountLiters {
            rows.append(KVRow(L10n.text("Fuel Remaining"), Format.fuelVolume(liters: liters, unit: preferences.fuelVolumeUnit), symbol: "fuelpump.fill"))
        }
        if let range = state.fuelSystem.rangeKm {
            rows.append(KVRow(L10n.text("Distance to Empty"), Format.distance(km: range, unit: preferences.distanceUnit), symbol: "gauge.with.needle"))
        }
        if let consumption = state.fuelSystem.averageConsumptionLPer100Km {
            rows.append(KVRow(L10n.text("Avg Fuel Consumption"), Format.fuelEconomy(lPer100Km: consumption, unit: preferences.fuelEconomyUnit), symbol: "chart.line.uptrend.xyaxis"))
        }
        if let running = state.fuelSystem.isEngineRunning {
            rows.append(KVRow(L10n.text("Engine State"), running ? L10n.text("Running") : L10n.text("Stopped"), symbol: "engine.combustion.fill", valueWarning: false))
        }
        if let hours = state.maintenance.service.engineHoursToService {
            rows.append(KVRow(L10n.text("Engine Hours to Service"), L10n.format("%d hrs", hours), symbol: "timer"))
        }
        if let fuelType = state.fuelSystem.type {
            rows.append(KVRow(L10n.text("Fuel Grade"), fuelType, symbol: "drop.fill"))
        }
        return rows
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "fuelpump.fill", title: L10n.text("Fuel & Engine"), color: .orange)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }
}
