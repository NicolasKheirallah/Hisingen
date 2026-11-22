import Foundation
import Testing
@testable import Hisingen

/// The maintenance log and the ownership assumption: reader-authored local data, validated on the
/// way in and removed by the same wipes every other per-vehicle table is removed by.
@Suite(.serialized)
@MainActor
struct MaintenanceLogAndOwnershipTests {
    private let vin = "YSMREPAIRTEST00001"

    private func database() -> VehicleDatabase {
        VehicleDatabase.inMemory()
    }

    // MARK: - Validation

    @Test
    func anEntryNeedsANameAndAcceptsEmptyOptionalFields() {
        let valid = MaintenanceEntryValidation.validate(
            title: "  Front brake pads ", costText: "", odometerText: "")

        #expect(valid.isValid)
        #expect(valid.title == "Front brake pads")
        #expect(valid.cost == nil)
        #expect(valid.odometerKm == nil)
    }

    @Test
    func aBlankNameIsRefusedWithAReason() {
        let invalid = MaintenanceEntryValidation.validate(
            title: "   ", costText: "1200", odometerText: "42000")

        #expect(invalid.isValid == false)
        #expect(invalid.invalidFields.contains(.title))
        #expect(invalid.reason(for: .title) != nil)
    }

    @Test
    func negativeOrUnparseableCostsAreRefused() {
        let negative = MaintenanceEntryValidation.validate(title: "Pads", costText: "-5", odometerText: "")
        let garbage = MaintenanceEntryValidation.validate(title: "Pads", costText: "12 kr", odometerText: "")

        #expect(negative.invalidFields.contains(.cost))
        #expect(garbage.invalidFields.contains(.cost))
    }

    @Test
    func aDecimalCommaAndGroupedOdometerParse() {
        let validation = MaintenanceEntryValidation.validate(
            title: "Service", costText: "1 200,50", odometerText: "42 000")

        #expect(validation.isValid)
        #expect(validation.cost == 1_200.50)
        #expect(validation.odometerKm == 42_000)
    }

    // MARK: - Storage

    @Test
    func entriesRoundTripNewestFirstAndDeleteByVehicle() throws {
        let database = database()
        let older = MaintenanceEntry(vin: vin, date: Date(timeIntervalSince1970: 1_790_000_000),
                                     odometerKm: 40_000, kind: .service, title: "Service",
                                     notes: "Oil and filters", cost: 3_200)
        let newer = MaintenanceEntry(vin: vin, date: Date(timeIntervalSince1970: 1_791_000_000),
                                     odometerKm: 42_500, kind: .tyres, title: "Winter tyres",
                                     notes: nil, cost: 8_000)
        #expect(database.addMaintenanceEntry(older) != nil)
        #expect(database.addMaintenanceEntry(newer) != nil)

        let stored = database.maintenanceEntries(for: vin)
        #expect(stored.map(\.id) == [newer.id, older.id])
        #expect(stored.first?.notes == nil)
        #expect(stored.last?.notes == "Oil and filters")
        #expect(stored.last?.odometerKm == 40_000)

        database.deleteMaintenanceEntry(id: older.id, vin: vin)
        #expect(database.maintenanceEntries(for: vin).map(\.id) == [newer.id])

        // Deleting with the wrong VIN leaves the row alone: the pair is the identity.
        database.deleteMaintenanceEntry(id: newer.id, vin: "SOMEONEELSE")
        #expect(database.maintenanceEntries(for: vin).count == 1)
    }

    @Test
    func theOwnershipAssumptionRoundTripsAndClearsWithAZeroPrice() {
        let database = database()
        let assumption = DepreciationAssumption(
            purchasePrice: 420_000, purchaseDate: Date(timeIntervalSince1970: 1_680_000_000),
            annualDeclinePercent: 15)
        #expect(database.saveOwnership(VehicleOwnership(vin: vin, assumption: assumption)))

        let stored = database.ownership(for: vin)
        #expect(stored?.assumption.purchasePrice == 420_000)
        #expect(stored?.assumption.annualDeclinePercent == 15)

        // A hand-edited rate above the ceiling is clamped on read.
        #expect(database.saveOwnership(VehicleOwnership(
            vin: vin,
            assumption: DepreciationAssumption(
                purchasePrice: 100_000, purchaseDate: Date(timeIntervalSince1970: 1_680_000_000),
                annualDeclinePercent: 900))))
        #expect(database.ownership(for: vin)?.assumption.annualDeclinePercent
            == DepreciationAssumption.maximumAnnualDeclinePercent)

        // Emptying the price is the reader clearing the assumption, not a car worth zero.
        #expect(database.saveOwnership(VehicleOwnership(
            vin: vin,
            assumption: DepreciationAssumption(
                purchasePrice: 0, purchaseDate: Date(timeIntervalSince1970: 1_680_000_000),
                annualDeclinePercent: 15))))
        #expect(database.ownership(for: vin) == nil)
    }

    @Test
    func wipingTheVehicleTakesTheLogAndTheAssumptionWithIt() throws {
        let database = database()
        let other = "YSMREPAIRTEST00002"
        for target in [vin, other] {
            #expect(database.addMaintenanceEntry(MaintenanceEntry(
                vin: target, date: Date(timeIntervalSince1970: 1_790_000_000), odometerKm: nil,
                kind: .repair, title: "Repair", notes: nil, cost: 500)) != nil)
            #expect(database.saveOwnership(VehicleOwnership(
                vin: target,
                assumption: DepreciationAssumption(
                    purchasePrice: 300_000, purchaseDate: Date(timeIntervalSince1970: 1_680_000_000),
                    annualDeclinePercent: 12))))
        }

        try database.wipeVehicleOrThrow(for: vin)

        #expect(database.maintenanceEntries(for: vin).isEmpty)
        #expect(database.ownership(for: vin) == nil)
        #expect(database.maintenanceEntries(for: other).count == 1)
        #expect(database.ownership(for: other) != nil)
    }

    @Test
    func theReportCarriesTheLogAndTheDepreciationForTheWindow() async {
        let database = database()
        let scoped = ScopedPreferences(label: "PeriodReportLoader")
        scoped.store.electricityPricePerKwh = 2.0
        #expect(database.saveOwnership(VehicleOwnership(
            vin: vin,
            assumption: DepreciationAssumption(
                purchasePrice: 400_000, purchaseDate: Date(timeIntervalSince1970: 1_680_000_000),
                annualDeclinePercent: 15))))
        let periodStart = Date(timeIntervalSince1970: 1_790_000_000)
        let periodEnd = periodStart.addingTimeInterval(30 * 24 * 3_600)
        #expect(database.addMaintenanceEntry(MaintenanceEntry(
            vin: vin, date: periodStart.addingTimeInterval(86_400), odometerKm: 41_000,
            kind: .service, title: "Service", notes: nil, cost: 2_500)) != nil)
        // Outside the window: it must not leak into this report.
        #expect(database.addMaintenanceEntry(MaintenanceEntry(
            vin: vin, date: periodStart.addingTimeInterval(-5 * 86_400), odometerKm: 40_000,
            kind: .repair, title: "Older repair", notes: nil, cost: 900)) != nil)

        let workspace = HistoryWorkspace(database: database, preferences: scoped.store)
        let period = ReportPeriod(cadence: .monthly, start: periodStart, end: periodEnd)
        let report = await workspace.periodReport(
            vin: vin, vehicleName: "Polestar 2", period: period, redacted: false)

        #expect(report.maintenance.map(\.title) == ["Service"])
        #expect(report.maintenanceCost == 2_500)
        #expect(report.depreciation != nil)
        #expect(report.depreciationBasis?.isEmpty == false)
        #expect(report.currencySymbol == scoped.store.currencySymbol)
    }
}
