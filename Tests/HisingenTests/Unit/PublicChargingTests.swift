import Foundation
import Testing
@testable import Hisingen

/// S13 — public charging: the manual-entry validation, the home/public split arithmetic, and the
/// stored-history upgrade that adds a place without changing any existing total.
@Suite("Public charging")
struct PublicChargingTests {
    private let vin = "PUBLIC-CHARGING-VIN"

    private func session(
        id: String,
        place: ChargingSessionPlace,
        energyKwh: Double,
        cost: Double?,
        tariff: Double? = nil,
        currency: String? = "kr",
        spotCost: Double? = nil
    ) -> HistoricalChargingSession {
        HistoricalChargingSession(
            id: id, vin: vin,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_003_600),
            startSoc: 20, endSoc: 60, energyDeliveredKwh: energyKwh,
            peakPowerKw: 0, averagePowerKw: 0, locationName: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            completionReason: .legacy, energySource: .legacyEstimate,
            confidence: .low, tariffPricePerKwh: tariff,
            currencySymbol: currency,
            summaryVersion: 2, estimatedCost: cost,
            spotEstimatedCost: spotCost, place: place
        )
    }

    // MARK: - Split arithmetic

    @Test
    func homeAndPublicBucketsAddUpToTheTotal() throws {
        let sessions = [
            session(id: "home-1", place: .home, energyKwh: 10, cost: 20),
            session(id: "public-1", place: .publicCharging, energyKwh: 30, cost: 120),
            session(id: "home-2", place: .home, energyKwh: 20, cost: nil, tariff: 1.5),
            session(id: "public-2", place: .publicCharging, energyKwh: 5, cost: nil)
        ]

        let split = ChargingCostSplit.resolve(
            sessions: sessions, policy: .fixed, fallbackPricePerKwh: 2, defaultCurrency: "kr"
        )

        let resolved = try #require(split)
        #expect(resolved.home.amount == 50)
        #expect(resolved.home.energyKwh == 30)
        #expect(resolved.home.sessionCount == 2)
        #expect(resolved.publicCharging.amount == 130)
        #expect(resolved.publicCharging.energyKwh == 35)
        #expect(resolved.publicCharging.sessionCount == 2)
        #expect(resolved.totalAmount == 180)
        #expect(resolved.totalSessionCount == 4)
        // The only session with no stored cost and no tariff falls back to the reader's rate.
        #expect(resolved.fallbackSessions == 1)
    }

    @Test
    func automaticPricingKeepsTheSplitConsistentWithTheSessionCost() {
        let sessions = [
            session(id: "home", place: .home, energyKwh: 10, cost: 99, spotCost: 10),
            session(id: "public", place: .publicCharging, energyKwh: 10, cost: 99)
        ]
        let policy = ElectricityRatePolicy(
            mode: .automatic, provider: .other, contract: .quarterHour,
            markupOrePerKwh: 0, otherChargesOrePerKwh: 0, includesVAT: true
        )

        let split = ChargingCostSplit.resolve(
            sessions: sessions, policy: policy, fallbackPricePerKwh: 2, defaultCurrency: "kr"
        )

        // Automatic mode prices the covered session from its market cost (10 × 1.25 VAT);
        // the uncovered one keeps the stored cost.
        #expect(abs((split?.home.amount ?? 0) - 12.5) < 0.0001)
        #expect(split?.publicCharging.amount == 99)
        #expect(split?.totalAmount == 111.5)
    }

    @Test
    func mixedCurrenciesHaveNoCombinedSplit() {
        let sessions = [
            session(id: "home", place: .home, energyKwh: 10, cost: 20, currency: "kr"),
            session(id: "public", place: .publicCharging, energyKwh: 10, cost: 3, currency: "€")
        ]

        #expect(ChargingCostSplit.resolve(
            sessions: sessions, policy: .fixed, fallbackPricePerKwh: 2, defaultCurrency: "kr"
        ) == nil)
    }

    // MARK: - Entry validation

    @Test
    func aReceiptWithATotalIsValidAndDerivesThePerKwhPrice() {
        let validation = ManualChargingSessionValidation.validate(
            energyText: "30", totalPriceText: "165", pricePerKwhText: ""
        )

        #expect(validation.isComplete)
        #expect(validation.resolvedTotalCost == 165)
        #expect(abs((validation.resolvedPricePerKwh ?? 0) - 5.5) < 0.0001)
    }

    @Test
    func aPricePerKwhIsAcceptedOnItsOwn() {
        let validation = ManualChargingSessionValidation.validate(
            energyText: "10", totalPriceText: "", pricePerKwhText: "2,5"
        )

        #expect(validation.isComplete)
        #expect(validation.resolvedTotalCost == 25)
        #expect(validation.resolvedPricePerKwh == 2.5)
    }

    @Test
    func energyAndAPriceAreRequired() {
        #expect(!ManualChargingSessionValidation.validate(
            energyText: "0", totalPriceText: "10", pricePerKwhText: "").isValid)
        let noPrice = ManualChargingSessionValidation.validate(
            energyText: "10", totalPriceText: "", pricePerKwhText: "")
        #expect(noPrice.isValid, "editing a stored session may leave its price unknown")
        #expect(!noPrice.isComplete, "a new session needs a price")
        #expect(noPrice.needsPrice)
        #expect(!ManualChargingSessionValidation.validate(
            energyText: "10", totalPriceText: "abc", pricePerKwhText: "").isValid)
        #expect(!ManualChargingSessionValidation.validate(
            energyText: "10", totalPriceText: "", pricePerKwhText: "abc").isValid)
    }

    // MARK: - Stored history

    @Test
    func aManualSessionIsStoredWithItsPlaceEnergyAndPrice() throws {
        let database = VehicleDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(2_400)

        let id = database.charging.addManualChargingSession(
            vin: vin, startedAt: start, endedAt: end, locationName: "Ionity Bäckebol",
            place: .publicCharging, energyKwh: 30, totalCost: 165,
            pricePerKwh: 5.5, currencySymbol: "kr"
        )

        let stored = try #require(database.charging.recentChargingSessions(for: vin).first)
        #expect(stored.id == id)
        #expect(stored.place == .publicCharging)
        #expect(stored.locationName == "Ionity Bäckebol")
        #expect(stored.energyDeliveredKwh == 30)
        #expect(stored.estimatedCost == 165)
        #expect(stored.tariffPricePerKwh == 5.5)
        #expect(stored.energySource == .manualEntry)
        #expect(stored.completionReason == .manualEntry)
        #expect(stored.lifecycleState == .completed)
        // No battery reading was entered; the percentage figures stay absent.
        #expect(stored.startSoc < 0)
        #expect(stored.endSoc == nil)
    }

    @Test
    func aStoredSessionCanBeEdited() throws {
        let database = VehicleDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = database.charging.addManualChargingSession(
            vin: vin, startedAt: start, endedAt: start.addingTimeInterval(1_800),
            locationName: "Ionity", place: .publicCharging, energyKwh: 30,
            totalCost: 165, pricePerKwh: nil, currencySymbol: "kr"
        )

        database.charging.updateChargingSessionDetails(
            id: id, vin: vin, startedAt: start, endedAt: start.addingTimeInterval(3_600),
            locationName: "Home", place: .home, energyKwh: 28,
            totalCost: 42, pricePerKwh: 1.5
        )

        let edited = try #require(database.charging.recentChargingSessions(for: vin).first)
        #expect(edited.place == .home)
        #expect(edited.locationName == "Home")
        #expect(edited.energyDeliveredKwh == 28)
        #expect(edited.estimatedCost == 42)
        #expect(edited.tariffPricePerKwh == 1.5)
        #expect(edited.endedAt == start.addingTimeInterval(3_600))
        // Editing does not rewrite where the row came from.
        #expect(edited.energySource == .manualEntry)
    }

    @Test
    func upgradingFromV9AddsThePlaceAndKeepsEveryStoredTotal() throws {
        let raw = try SQLiteDatabase.inMemory()
        let database = VehicleDatabase(database: raw)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = database.charging.startChargingSession(
            vin: vin, startSoc: 20, startedAt: start
        )
        database.charging.completeChargingSession(
            id: id, endSoc: 60, energyDeliveredKwh: 30,
            peakPowerKw: 11, averagePowerKw: 11,
            endedAt: start.addingTimeInterval(3_600),
            lifecycleState: .completed, completionReason: .targetReached,
            energySource: .socCapacityEstimate, confidence: .medium,
            estimatedCost: 42
        )
        #expect(try #require(database.charging.recentChargingSessions(for: vin).first).place == .home)

        // Rewind the store to the shape a v9 build wrote, then let this build migrate it.
        try raw.execute(sql: """
            ALTER TABLE charging_sessions DROP COLUMN charging_place;
            PRAGMA user_version = 9;
            """)
        #expect(try userVersion(raw) == 9)

        let upgraded = VehicleDatabase(database: raw)
        let stored = try #require(upgraded.charging.recentChargingSessions(for: vin).first)

        #expect(try userVersion(raw) == VehicleDatabase.latestSchemaVersion)
        #expect(stored.place == .home, "rows written before the place existed read as home")
        #expect(stored.energyDeliveredKwh == 30)
        #expect(stored.estimatedCost == 42)
        #expect(stored.endSoc == 60)
    }

    private func userVersion(_ raw: SQLiteDatabase) throws -> Int {
        try raw.query(sql: "PRAGMA user_version;") { _ in } process: { stmt -> Int in
            guard try stmt.stepOrThrow() else { return -1 }
            return Int(stmt.columnInt64(at: 0) ?? 0)
        }
    }
}
