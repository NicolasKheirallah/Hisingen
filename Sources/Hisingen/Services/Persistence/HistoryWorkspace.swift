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

    struct DashboardQuery: Sendable {
        var vin: String
        var range: ClosedRange<Date>?
        var rowCap: Int
        var tripCap: Int
        var capacityKwh: Double
        var hasElectricRange: Bool
        var hasCombustionEngine: Bool
    }

    /// A period change can reuse the lifetime series supplied by the caller.
    func dashboard(matching query: DashboardQuery, loadLifetime: Bool,
                   keeping existing: VehicleHistoryLedger.LifetimeSnapshot) async -> HistoryDashboardLoadResult {
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
    func recentRecords(vin: String) async -> VehicleHistoryLedger.RecentRecords {
        let database = database
        return await Task.detached(priority: .userInitiated) {
            database.history.recent(vin: vin)
        }.value
    }

    /// Completed, reconciled charging sessions for the vehicle-level charging history card.
    func persistentChargingSessions(vin: String, state: VehicleState) async -> [ChargingSession] {
        let database = database
        let capacity = usableCapacityKwh(vin: vin, state: state)
        return await Task.detached(priority: .userInitiated) {
            database.charging.recentChargingSessions(for: vin)
                .map { database.charging.domainSession(from: $0, usableCapacityKwh: capacity) }
                .filter { ($0.percentageAdded > 0 && $0.kwhDelivered > 0) || ($0.wallbox?.energyKwh ?? 0) > 0 }
        }.value
    }

    /// Trips derived from recorded telemetry, for the handover pack. Entries carry coordinates;
    /// the caller decides what leaves the Mac.
    func tripHistory(vin: String) async -> [TripHistoryEntry] {
        let database = database
        return await Task.detached(priority: .userInitiated) {
            database.history.derivedTrips(for: vin, limit: 5_000)
        }.value
    }

    struct SessionCurves: Sendable {
        var samples: [HistoricalChargingSample]
        var current: [HistoryInsights.ChargingCurvePoint]
        var previous: [HistoryInsights.ChargingCurvePoint]
        /// What the home charger itself reported during the session, if it was paired and recording.
        var chargerPower: [VehicleMetricRecord] = []
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
            let end = (session.endedAt ?? Date()).addingTimeInterval(120)
            let chargerPower = database.history
                .metrics(for: session.vin, metric: .chargerPower, since: session.startedAt.addingTimeInterval(-120))
                .filter { $0.timestamp <= end }
            return SessionCurves(samples: samples, current: current, previous: previousCurve, chargerPower: chargerPower)
        }.value
    }

    // MARK: - Edits

    @discardableResult
    func addFuelEntry(vin: String, date: Date, liters: Double,
                      pricePerLiter: Double, odometerKm: Double?) -> Bool {
        database.history.addFuelEntry(vin: vin, date: date, liters: liters,
                                      pricePerLiter: pricePerLiter, odometerKm: odometerKm)
    }

    /// Adds a session the reader typed in. The ledger owns the insert; the view only passes
    /// the figures through the workspace seam.
    @discardableResult
    func addManualChargingSession(
        vin: String, startedAt: Date, endedAt: Date, locationName: String?,
        place: ChargingSessionPlace, energyKwh: Double, totalCost: Double?,
        pricePerKwh: Double?
    ) -> String {
        database.charging.addManualChargingSession(
            vin: vin, startedAt: startedAt, endedAt: endedAt, locationName: locationName,
            place: place, energyKwh: energyKwh, totalCost: totalCost,
            pricePerKwh: pricePerKwh, currencySymbol: preferences.currencySymbol
        )
    }

    func updateChargingSession(
        id: String, vin: String, startedAt: Date, endedAt: Date, locationName: String?,
        place: ChargingSessionPlace, energyKwh: Double, totalCost: Double?,
        pricePerKwh: Double?
    ) {
        database.charging.updateChargingSessionDetails(
            id: id, vin: vin, startedAt: startedAt, endedAt: endedAt,
            locationName: locationName, place: place, energyKwh: energyKwh,
            totalCost: totalCost, pricePerKwh: pricePerKwh
        )
    }

    func setSessionNote(_ note: String, sessionID: String, vin: String) {
        database.history.setSessionNote(note, sessionID: sessionID, vin: vin)
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

    /// The CSV entry's workbook: the same rows, typed, plus a summary sheet. Built from the CSV
    /// string so the two files cannot disagree about a value, and so every entry in the export
    /// menu gains the format without a second row-building path.
    func exportXLSX(_ kind: ExportKind, scope: ExportScope, vin: String, selectedSessionID: String?,
                    periodTrips: [TripHistoryEntry], periodSessions: [HistoricalChargingSession],
                    title: String, vehicle: String) async -> Data? {
        let csv = await exportCSV(kind, scope: scope, vin: vin, selectedSessionID: selectedSessionID,
                                  periodTrips: periodTrips, periodSessions: periodSessions)
        guard !csv.isEmpty else { return nil }
        let scopeLabel: String
        switch scope {
        case .selectedPeriod:
            scopeLabel = L10n.text("Selected period")
        case .fullHistory:
            // The samples export is one session even though it is built by the full-history path.
            scopeLabel = kind == .sessionSamples ? L10n.text("Selected session") : L10n.text("Full history")
        }
        return await Task.detached(priority: .userInitiated) {
            HistoryWorkbook.workbook(csv: csv, title: title, vehicle: vehicle,
                                     scope: scopeLabel)?.data()
        }.value
    }

    /// GPX 1.1 for the trips in scope. A trip with no recorded position contributes no track.
    func exportTripsGPX(scope: ExportScope, vin: String, periodTrips: [TripHistoryEntry],
                        vehicleName: String) async -> Data {
        let trips: [TripHistoryEntry]
        switch scope {
        case .selectedPeriod:
            trips = periodTrips
        case .fullHistory:
            trips = await tripHistory(vin: vin)
        }
        return GPXExport.data(trips: trips, vehicleName: vehicleName)
    }

    /// Prices uncosted sessions once spot-price coverage reaches them. Historical day files
    /// are fetched lazily, bounded to the seven most recent uncovered days so a long history
    /// cannot turn one card appearance into an unbounded fetch storm. Returns how many
    /// sessions received a price.
    func backfillSpotEstimatedCosts(vin: String, zone: ElspotZone, contract: ElectricityPriceContract = .quarterHour) async -> Int {
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
            return database.charging.backfillSpotEstimatedCosts(vin: vin, prices: contract.settle(prices))
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

// MARK: - Reports, maintenance log and ownership

/// S26's local data: the reader's own maintenance log and ownership assumption, and the report a
/// period produces from history the app already stores. Nothing here calls a provider or asks for
/// a price Hisingen does not have: the trip costs come from the car's reported consumption and the
/// reader's rate settings, and depreciation is arithmetic on their stated assumption.
extension HistoryWorkspace {
    // MARK: Maintenance log

    func maintenanceEntries(for vin: String) -> [MaintenanceEntry] {
        database.maintenanceEntries(for: vin)
    }

    @discardableResult
    func addMaintenanceEntry(_ entry: MaintenanceEntry) -> MaintenanceEntry? {
        database.addMaintenanceEntry(entry)
    }

    func deleteMaintenanceEntry(id: String, vin: String) {
        database.deleteMaintenanceEntry(id: id, vin: vin)
    }

    // MARK: Ownership

    func ownership(for vin: String) -> VehicleOwnership? {
        database.ownership(for: vin)
    }

    @discardableResult
    func saveOwnership(_ ownership: VehicleOwnership) -> Bool {
        database.saveOwnership(ownership)
    }

    // MARK: Period report

    /// Builds one window's report from local data only. Trips and charging sessions come from the
    /// history ledger, the rate policy from preferences, and the maintenance log from the reader's
    /// own entries; a window with no readings still produces a report, because "no trips" is an
    /// answer the reader asked for.
    func periodReport(
        vin: String,
        vehicleName: String,
        period: ReportPeriod,
        redacted: Bool,
        now: Date = Date()
    ) async -> PeriodReportInput {
        let policy = preferences.electricityRatePolicy
        let fallbackPricePerKwh = preferences.electricityPricePerKwh
        let currencySymbol = preferences.currencySymbol
        let distanceUnit = preferences.distanceUnit
        let spotAverage = policy.isAutomatic
            ? ReportPricing.averageSpot(
                database.electricityPrices.prices(zone: preferences.electricityPriceZone),
                over: period)
            : nil
        let database = database
        let upperBound = max(period.start, period.end.addingTimeInterval(-1))
        let range = ClosedRange(uncheckedBounds: (lower: period.start, upper: upperBound))

        return await Task.detached(priority: .userInitiated) {
            let snapshot = database.history.dashboard(
                vin: vin, range: range, rowCap: 4_000, tripLimit: 4_000, chargingCapacity: 0)
            let price = ReportPricing.retailPricePerKwh(
                policy: policy, fallbackPricePerKwh: fallbackPricePerKwh,
                averageSpotSekPerKwh: spotAverage)
            let trips = snapshot.trips.map { trip -> PeriodReportTrip in
                let energy = TripCost.energyKwh(
                    distanceKm: trip.distanceKm, consumptionKwhPer100Km: trip.averageConsumption)
                return PeriodReportTrip(
                    endedAt: trip.endedAt,
                    distanceKm: trip.distanceKm,
                    energyKwh: energy,
                    cost: TripCost.cost(energyKwh: energy, pricePerKwh: price.price),
                    priceUsedFallback: price.usedFallback)
            }
            let charges = snapshot.chargingSessions.map { session in
                PeriodReportCharge(
                    startedAt: session.startedAt,
                    energyKwh: session.energyDeliveredKwh,
                    cost: session.resolvedCost(
                        policy: policy, fallbackPricePerKwh: fallbackPricePerKwh).amount)
            }
            let maintenance = database.maintenanceEntries(for: vin)
                .filter { period.contains($0.date) }
            let ownership = database.ownership(for: vin)
            let figure = ownership.flatMap {
                Depreciation.figure(
                    assumption: $0.assumption, periodStart: period.start, periodEnd: period.end)
            }
            let basis = ownership.map {
                Depreciation.basisText(assumption: $0.assumption, currencySymbol: currencySymbol)
            }
            return PeriodReportInput(
                vehicleName: vehicleName,
                vin: vin,
                period: period,
                trips: trips.sorted { $0.endedAt > $1.endedAt },
                charges: charges.sorted { $0.startedAt > $1.startedAt },
                maintenance: maintenance.sorted { $0.date > $1.date },
                depreciation: figure,
                depreciationBasis: basis,
                currencySymbol: currencySymbol,
                distanceUnit: distanceUnit,
                generatedAt: now,
                redacted: redacted)
        }.value
    }
}
