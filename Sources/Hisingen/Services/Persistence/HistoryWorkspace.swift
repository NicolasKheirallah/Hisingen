import Foundation

/// The one seam between the panel's History surfaces and the history ledgers. Owns the
/// loading recipe — usable-capacity resolution, the off-main hop, the cancellation guard
/// shape — so a view states *what* to load and never holds `VehicleDatabase` itself.
/// The ledgers remain the deep half; this module is deep enough that a change to how
/// history loads (row caps, capacity policy, export scoping) touches one file.
@MainActor
final class HistoryWorkspace {
    private let database: VehicleDatabase
    private let preferences: PreferencesStore

    init(database: VehicleDatabase, preferences: PreferencesStore) {
        self.database = database
        self.preferences = preferences
    }

    // Records the views render, re-exported here so UI code never names the database.
    typealias FuelEntry = VehicleDatabase.FuelEntry
    typealias CabinClimateRecord = VehicleDatabase.CabinClimateRecord
    typealias ConnectivityRecord = VehicleDatabase.ConnectivityRecord

    // MARK: - Capacity

    /// The pack capacity a query or chart should assume: the reader's specification
    /// override when one exists, otherwise what the vehicle reports.
    func usableCapacityKwh(vin: String, state: VehicleState) -> Double {
        state.configuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: vin)
        ).kwh
    }

    // MARK: - Dashboard

    /// Everything that decides what the period-scoped dashboard load returns. The view
    /// also feeds this value to `.task(id:)`, so the reload trigger and the query inputs
    /// are one thing and cannot drift apart.
    struct DashboardQuery: Equatable, Hashable, Sendable {
        var vin: String
        var range: ClosedRange<Date>?
        var rowCap: Int
        var tripCap: Int
        var capacityKwh: Double
        var hasElectricRange: Bool
        var hasCombustionEngine: Bool
        /// The view's lifetime-cache identity; documented here because the workspace
        /// trusts it to decide `loadLifetime` honestly.
        var lifetimeKey: String
    }

    /// Loads the period snapshot, optionally the lifetime series, and the presentation
    /// build, off the main actor. Returns nil only when the caller's task was cancelled
    /// while waiting.
    func dashboard(matching query: DashboardQuery, loadLifetime: Bool,
                   keeping existing: VehicleHistoryLedger.LifetimeSnapshot) async -> HistoryDashboardLoadResult? {
        let database = database
        return await Task.detached(priority: .userInitiated) {
            let dashboard = database.history.dashboard(
                vin: query.vin, range: query.range, rowCap: query.rowCap,
                tripLimit: query.tripCap, chargingCapacity: query.capacityKwh
            )
            let lifetime = loadLifetime
                ? database.history.lifetime(vin: query.vin, hasCombustionEngine: query.hasCombustionEngine)
                : existing
            return HistoryDashboardLoadResult(
                dashboard: dashboard,
                lifetime: lifetime,
                presentation: HistoryPresentationSnapshot.build(
                    dashboard: dashboard, lifetime: lifetime,
                    hasElectricRange: query.hasElectricRange,
                    hasCombustionEngine: query.hasCombustionEngine
                )
            )
        }.value
    }

    /// The Info tab's recent-records bundle.
    func recentRecords(for state: VehicleState) async -> VehicleHistoryLedger.RecentRecords {
        let database = database
        let vin = state.identity.vin
        let capacity = usableCapacityKwh(vin: vin, state: state)
        return await Task.detached(priority: .userInitiated) {
            database.history.recent(vin: vin, chargingCapacityKwh: capacity)
        }.value
    }

    /// Completed, reconciled charging sessions for the vehicle-level charging history card.
    func persistentChargingSessions(vin: String, state: VehicleState) async -> [ChargingSession] {
        let database = database
        let capacity = usableCapacityKwh(vin: vin, state: state)
        return await Task.detached(priority: .userInitiated) {
            database.charging.recentChargingSessions(for: vin)
                .map { database.charging.domainSession(from: $0, usableCapacityKwh: capacity) }
                .filter { $0.percentageAdded > 0 && $0.kwhDelivered > 0 }
        }.value
    }

    struct SessionCurves: Sendable {
        var samples: [HistoricalChargingSample]
        var current: [HistoryInsights.ChargingCurvePoint]
        var previous: [HistoryInsights.ChargingCurvePoint]
    }

    /// The selected session's samples and curve, plus the prior session's curve when the
    /// reader asked to overlay it.
    func sessionCurves(for session: HistoricalChargingSession,
                       overlaying previous: HistoricalChargingSession?) async -> SessionCurves {
        let database = database
        return await Task.detached(priority: .userInitiated) {
            let samples = database.charging.reconciledSamples(for: session)
            let current = HistoryInsights.chargingCurve(from: samples)
            let previousCurve = previous.map {
                HistoryInsights.chargingCurve(from: database.charging.reconciledSamples(for: $0))
            } ?? []
            return SessionCurves(samples: samples, current: current, previous: previousCurve)
        }.value
    }

    // MARK: - Edits

    @discardableResult
    func addFuelEntry(vin: String, date: Date, liters: Double,
                      pricePerLiter: Double, odometerKm: Double?) -> Bool {
        database.history.addFuelEntry(vin: vin, date: date, liters: liters,
                                      pricePerLiter: pricePerLiter, odometerKm: odometerKm)
    }

    func deleteFuelEntry(id: Int64) {
        database.history.deleteFuelEntry(id: id)
    }

    func setTripPurpose(_ purpose: TripPurpose?, tripID: String, vin: String) {
        database.history.setTripPurpose(purpose, tripID: tripID, vin: vin)
    }

    // MARK: - Exports

    enum ExportScope: String, CaseIterable, Identifiable, Sendable {
        case fullHistory
        case selectedPeriod
        var id: String { rawValue }
    }

    enum ExportKind: String, CaseIterable, Sendable {
        case trips
        case chargingSessions
        case sessionSamples
        case batteryHealth
        case airQuality
        case telemetry
        case commandAudits
        case fuelEntries
        case cabinClimate
    }

    /// Builds the CSV for one export menu entry. The full-history variants assemble in the
    /// ledger off-main; the selected-period variants format the rows the view already has.
    /// The scope branch lives here so the nine menu entries cannot grow nine more ternaries.
    func exportCSV(_ kind: ExportKind, scope: ExportScope, vin: String, selectedSessionID: String?,
                   periodTrips: [TripHistoryEntry], periodSessions: [HistoricalChargingSession]) async -> String {
        let database = database
        switch scope {
        case .selectedPeriod:
            switch kind {
            case .trips: return HistoryExport.tripsCSV(periodTrips)
            case .chargingSessions: return HistoryExport.chargingSessionsCSV(periodSessions)
            case .sessionSamples, .batteryHealth, .airQuality, .telemetry,
                 .commandAudits, .fuelEntries, .cabinClimate:
                break // no period-scoped variant; falls through to the full-history build
            }
        case .fullHistory:
            break
        }
        return await Task.detached(priority: .userInitiated) {
            switch kind {
            case .trips: return database.history.exportTripsCSV(for: vin)
            case .chargingSessions: return database.charging.exportChargingSessionsCSV(for: vin)
            case .sessionSamples:
                guard let selectedSessionID else { return "" }
                return database.charging.exportChargingSamplesCSV(sessionID: selectedSessionID)
            case .batteryHealth: return database.history.exportBatteryHealthCSV(for: vin)
            case .airQuality: return database.history.exportAirQualityCSV(for: vin)
            case .telemetry: return database.history.exportTelemetryCSV(for: vin)
            case .commandAudits: return database.history.exportCommandAuditsCSV(for: vin)
            case .fuelEntries: return database.history.exportFuelEntriesCSV(for: vin)
            case .cabinClimate: return database.history.exportCabinClimateCSV(for: vin)
            }
        }.value
    }

    /// Prices uncosted sessions once spot-price coverage reaches them. Historical day files
    /// are fetched lazily, bounded to the seven most recent uncovered days so a long history
    /// cannot turn one card appearance into an unbounded fetch storm. Returns how many
    /// sessions received a price.
    func backfillSpotEstimatedCosts(vin: String, zone: ElspotZone) async -> Int {
        let database = database
        let calendar = ElectricityPriceService.stockholmCalendar
        return await Task.detached(priority: .userInitiated) { () -> Int in
            var prices = await ElectricityPriceService.shared.prices(for: zone)
            let uncovered = database.charging.sessionsMissingSpotCost(vin: vin, limit: 400)
            let covered = Set(prices.map { calendar.startOfDay(for: $0.startDate) })
            let days = Set(uncovered.compactMap { session -> Date? in
                guard session.endedAt != nil else { return nil }
                let day = calendar.startOfDay(for: session.startedAt)
                return covered.contains(day) ? nil : day
            })
            for day in days.sorted(by: >).prefix(7)
            where Date().timeIntervalSince(day) < 8 * 86_400 {
                prices = await ElectricityPriceService.shared.historicalPrices(zone: zone, day: day)
            }
            guard !prices.isEmpty else { return 0 }
            return database.charging.backfillSpotEstimatedCosts(vin: vin, prices: prices)
        }.value
    }

    /// The full-database JSON backup. Returns nil when the backup could not be created.
    func exportBackupJSON(includeCoordinates: Bool) async -> Data? {
        let database = database
        return await Task.detached(priority: .userInitiated) {
            try? database.exportBackupJSON(includeCoordinates: includeCoordinates)
        }.value
    }
}
