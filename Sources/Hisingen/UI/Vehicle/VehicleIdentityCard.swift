import SwiftUI

@MainActor
struct VehicleIdentityCard: View {
    let state: VehicleState
    let features: FeatureSelection
    let preferences: PreferencesStore

    static func make(state: VehicleState, features: FeatureSelection, preferences: PreferencesStore) -> AnyView? {
        let card = Self(state: state, features: features, preferences: preferences)
        guard !card.rows.isEmpty else { return nil }
        return AnyView(card)
    }

    private var rows: [KVRow] {
        var rows: [KVRow] = []
        if features.contains(.vehicleIdentity) {
            if let plate = state.identity.registrationNo, !plate.isEmpty {
                rows.append(KVRow(L10n.text("License Plate"), plate, symbol: "rectangle.inset.filled"))
            }
            rows.append(KVRow(L10n.text("VIN"), state.identity.vin, symbol: "number"))
        }
        if features.contains(.vehicleAvailability), state.identity.availability == .available {
            rows.append(KVRow(L10n.text("Cloud Connectivity"), state.identity.availability.displayName, symbol: "antenna.radiowaves.left.and.right"))
        }
        if features.contains(.vehicleHealth), let km = state.maintenance.odometerKm {
            rows.append(KVRow(L10n.text("Odometer"), Format.distance(km: km, grouped: true, unit: preferences.distanceUnit), symbol: "speedometer"))
        }
        if features.contains(.vehicleHealth), let days = state.maintenance.service.daysToService {
            var value = L10n.format("in %d days", days)
            if let km = state.maintenance.service.distanceToServiceKm { value += " / \(Format.distance(km: km, unit: preferences.distanceUnit))" }
            if let trigger = state.formattedServiceTrigger { value += " (\(trigger))" }
            rows.append(KVRow(L10n.text("Service Due"), value, symbol: "wrench.and.screwdriver", valueWarning: days < 30))
        }
        if features.contains(.vehicleHealth), let hours = state.maintenance.service.engineHoursToService, hours > 0 {
            rows.append(KVRow(L10n.text("Engine Hours"), "\(hours) h", symbol: "timer"))
        }
        if features.contains(.tripMeters) {
            if let km = state.tripComputer.manualTripKm { rows.append(KVRow(L10n.text("Manual Trip Meter"), Format.distance(km: Int(km.rounded()), unit: preferences.distanceUnit), symbol: "m.circle")) }
            if let km = state.tripComputer.automaticTripKm { rows.append(KVRow(L10n.text("Auto Trip Meter"), Format.distance(km: Int(km.rounded()), unit: preferences.distanceUnit), symbol: "a.circle")) }
            if let speed = state.tripComputer.manualAverageSpeedKmH, speed > 0 { rows.append(KVRow(L10n.text("Average Speed (TM)"), Format.speed(kmH: speed, unit: preferences.distanceUnit), symbol: "gauge.with.needle")) }
            if let speed = state.tripComputer.automaticAverageSpeedKmH, speed > 0 { rows.append(KVRow(L10n.text("Average Speed (AT)"), Format.speed(kmH: speed, unit: preferences.distanceUnit), symbol: "gauge.with.needle")) }
            if let speed = state.tripComputer.averageSpeedKmH, speed > 0 { rows.append(KVRow(L10n.text("Average Speed"), Format.speed(kmH: Int(speed.rounded()), unit: preferences.distanceUnit), symbol: "gauge.with.needle")) }
        }
        return rows
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "car.side", title: L10n.text("Vehicle Identity"), color: Color.accentColor)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }
}
