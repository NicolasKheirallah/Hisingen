import AppIntents
import Foundation

struct GetVehicleBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Battery"
    static let description = IntentDescription("Returns the battery level, range, and charging status of a vehicle.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let preferences = PreferencesStore.shared
        let store = AutomationHandoff.sharedStateStore
        guard let vin = AutomationHandoff.resolveVIN(from: vehicle),
              let state = store.snapshot(for: vin) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        var parts: [String] = []
        if let battery = state.energy.batteryPercentage {
            parts.append(L10n.format("%.0f%% battery", battery))
        } else if let fuel = state.fuelSystem.levelPercent {
            parts.append(L10n.format("%.0f%% fuel", fuel))
        }
        if let range = state.primaryRangeKm {
            parts.append(L10n.format("%d %@ range", preferences.distanceUnit.convert(km: range), preferences.distanceUnit.suffix))
        }
        if state.isCharging {
            if let power = state.energy.powerWatts, power > 0 {
                parts.append(L10n.format("charging at %@", Format.kilowatts(watts: power)))
            } else {
                parts.append(L10n.text("currently charging"))
            }
        }
        let summary = parts.joined(separator: ", ")
        let nick = preferences.vehicleNickname(for: vin)
        let model = nick.isEmpty ? (state.identity.modelName ?? L10n.text("Vehicle")) : nick
        let response = L10n.format("%@: %@.", model, summary)
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

struct GetGarageStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Garage Status"
    static let description = IntentDescription("Returns the status of all vehicles in your garage.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        let preferences = PreferencesStore.shared
        let store = AutomationHandoff.sharedStateStore
        var knownVINs: [String] = []
        for brand in VehicleBrand.allCases {
            let vin = preferences.vin(for: brand)
            if !vin.isEmpty && !knownVINs.contains(vin) { knownVINs.append(vin) }
        }
        if knownVINs.isEmpty && !preferences.vin.isEmpty { knownVINs.append(preferences.vin) }

        var lines: [String] = []
        for vin in knownVINs {
            guard let state = store.snapshot(for: vin) else { continue }
            let nick = preferences.vehicleNickname(for: vin)
            let name = nick.isEmpty ? (state.identity.modelName ?? state.model.brand.displayName) : nick
            var parts: [String] = []
            if let battery = state.energy.batteryPercentage {
                parts.append(L10n.format("%.0f%%", battery))
            } else if let fuel = state.fuelSystem.levelPercent {
                parts.append(L10n.format("%.0f%% fuel", fuel))
            }
            if let range = state.primaryRangeKm {
                parts.append(Format.distance(km: range, unit: preferences.distanceUnit))
            }
            if state.isCharging { parts.append(L10n.text("⚡ charging")) }
            if let locked = state.exteriorStatus?.isLocked { parts.append(locked ? L10n.text("locked") : L10n.text("unlocked")) }
            lines.append(L10n.format("%@: %@.", name, parts.joined(separator: ", ")))
        }

        if lines.isEmpty {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicles or telemetry found in your garage.")))
        }
        let response = L10n.format("%@.", lines.joined(separator: ". "))
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

struct GetVehicleStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Vehicle Status"
    static let description = IntentDescription("Returns lock, opening, and attention status from the latest Hisingen snapshot.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        var details: [String] = []
        if let locked = state.exteriorStatus?.isLocked { details.append(locked ? L10n.text("locked") : L10n.text("unlocked")) }
        if let exterior = state.exteriorStatus, !exterior.itemsNeedingAttention.isEmpty {
            details.append(exterior.itemsNeedingAttention.map(\.displayName).joined(separator: ", "))
        }
        details.append(state.stateSummary.message)
        let nick = preferences.vehicleNickname(for: state.identity.vin)
        let name = nick.isEmpty ? (state.identity.modelName ?? L10n.text("Vehicle")) : nick
        let response = L10n.format("%@: %@. Data %@.", name, details.joined(separator: "; "), Format.relativeAge(since: state.dataTimestamp))
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

struct GetRecentTripsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Trip Summary"
    static let description = IntentDescription("Returns locally derived trip distance and driving time for the last seven days.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        // Push the 7-day bound into SQL instead of decoding up to 20k telemetry rows per run.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let trips = VehicleDatabase.shared.history.derivedTrips(for: state.identity.vin, limit: 1_000, since: cutoff)
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        let minutes = Int(trips.reduce(0) { $0 + $1.duration } / 60)
        let response = L10n.format("Last 7 days: %d inferred trips, %@, %@ driving.",
                                   trips.count,
                                   Format.distance(km: distance, decimals: 1, unit: preferences.distanceUnit),
                                   Format.shortDuration(minutes: minutes))
        return .result(value: response, dialog: IntentDialog(stringLiteral: response))
    }
}

struct RefreshTelemetryIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Vehicle Data"
    static let description = IntentDescription("Asks Hisingen to fetch fresh vehicle data from the provider now.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some ProvidesDialog {
        guard let refresh = AutomationHandoff.refreshAction else {
            return .result(dialog: IntentDialog(stringLiteral: L10n.text("Hisingen is still launching. Try again in a moment.")))
        }
        refresh()
        return .result(dialog: IntentDialog(stringLiteral: L10n.text("Refresh requested – Hisingen is fetching the latest vehicle data.")))
    }
}

struct GetEnergyBreakdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Energy Breakdown"
    static let description = IntentDescription("Returns the vehicle's electrical energy consumption breakdown across driving, climate, and battery conditioning.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        guard let breakdown = state.energy.diagnostics?.energyBreakdown, breakdown.hasData else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("Energy breakdown data is not available for this vehicle.")))
        }
        var lines: [String] = []
        if let d = breakdown.driving, let wh = d.wattHours {
            lines.append(L10n.format("Traction: %.1f kWh", wh / 1_000))
        }
        if let c = breakdown.climate, let wh = c.wattHours {
            lines.append(L10n.format("Climate: %.1f kWh", wh / 1_000))
        }
        if let b = breakdown.battery, let wh = b.wattHours {
            lines.append(L10n.format("Battery Thermal: %.1f kWh", wh / 1_000))
        }
        if let o = breakdown.other, let wh = o.wattHours {
            lines.append(L10n.format("Electronics: %.1f kWh", wh / 1_000))
        }
        let summary = lines.isEmpty ? L10n.text("No energy consumption recorded.") : lines.joined(separator: ", ")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

struct GetTirePressuresIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Tire Pressures"
    static let description = IntentDescription("Returns the current tire pressures and statuses for all wheels.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, _) = AutomationHandoff.snapshot(for: vehicle) else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("No vehicle telemetry available in Hisingen.")))
        }
        guard let tyres = state.maintenance.details?.tyres, !tyres.isEmpty else {
            return .result(value: "--", dialog: IntentDialog(stringLiteral: L10n.text("Tire status data is not available for this vehicle.")))
        }
        let lines = tyres.map { tyre -> String in
            let posName = tyre.position.displayName
            if let kpa = tyre.kilopascals {
                let targetStr = tyre.referenceKilopascals.map { " (target \(Int($0.rounded())) kPa)" } ?? ""
                return "\(posName): \(Int(kpa.rounded())) kPa\(targetStr)"
            }
            return "\(posName): \(tyre.warning.displayName)"
        }
        let summary = lines.joined(separator: "; ")
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}
