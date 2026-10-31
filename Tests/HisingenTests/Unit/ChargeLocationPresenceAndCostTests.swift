import Foundation
import Testing
@testable import Hisingen

/// Presence at a saved charge location is a proximity check against the saved coordinates, and
/// the charge cost by location groups sessions by place and currency without adding currencies.
@Suite("Charge location presence and cost by location")
struct ChargeLocationPresenceAndCostTests {
    private let home = (latitude: 57.7089, longitude: 11.9746)
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func spot(
        _ id: String, alias: String, latitude: Double? = nil, longitude: Double? = nil, kind: Int = 2
    ) -> ChargeLocationSnapshot {
        ChargeLocationSnapshot(
            id: id, alias: alias, latitude: latitude, longitude: longitude, ampLimit: 16, minimumSoc: 0,
            optimisedChargingEnabled: false, optimisedChargingMode: 0, kind: kind
        )
    }

    /// Moves north by `meters` from the home point; one degree of latitude is about 111.2 km.
    private func offset(northMeters meters: Double) -> (latitude: Double, longitude: Double) {
        (home.latitude + meters / 111_195, home.longitude)
    }

    private func position(_ point: (latitude: Double, longitude: Double), at date: Date? = nil) -> VehicleLocation {
        VehicleLocation(latitude: point.latitude, longitude: point.longitude, timestamp: date)
    }

    // MARK: - Proximity

    @Test
    func distanceMatchesKnownGeometry() {
        let metres = ChargeLocationPresence.distanceMeters(0, 0, 1, 0)
        #expect(abs(metres - 111_195) < 50)
        #expect(ChargeLocationPresence.distanceMeters(home.latitude, home.longitude,
                                                      home.latitude, home.longitude) == 0)
    }

    @Test
    func vehicleWithinRadiusIsAtTheSavedLocation() {
        let locations = [spot("home", alias: "Home", latitude: home.latitude, longitude: home.longitude)]
        let arrived = Date(timeIntervalSince1970: 1_790_000_000)
        let presence = ChargeLocationPresence.resolve(
            location: position(offset(northMeters: 40), at: arrived), locations: locations, previous: nil
        )
        #expect(presence?.locationID == "home")
        #expect(presence?.alias == "Home")
        #expect(presence?.since == arrived)
        #expect(presence?.source == .proximity)
    }

    @Test
    func vehicleBeyondRadiusIsNotAtAnyLocation() {
        let locations = [spot("home", alias: "Home", latitude: home.latitude, longitude: home.longitude)]
        let presence = ChargeLocationPresence.resolve(
            location: position(offset(northMeters: 400)), locations: locations, previous: nil
        )
        #expect(presence == nil)
    }

    @Test
    func nearestSavedLocationWinsWhenTwoAreInRange() {
        let locations = [
            spot("far", alias: "Office", latitude: home.latitude + 100 / 111_195, longitude: home.longitude),
            spot("near", alias: "Home", latitude: home.latitude + 20 / 111_195, longitude: home.longitude)
        ]
        let presence = ChargeLocationPresence.resolve(
            location: position(offset(northMeters: 0)), locations: locations, previous: nil
        )
        #expect(presence?.locationID == "near")
    }

    @Test
    func recentLocationsAndCoordinateFreeSavesAreNotMatched() {
        let locations = [
            spot("recent", alias: "Recent stop", latitude: home.latitude, longitude: home.longitude, kind: 1),
            spot("unplaced", alias: "No coordinates")
        ]
        let presence = ChargeLocationPresence.resolve(
            location: position(offset(northMeters: 0)), locations: locations, previous: nil
        )
        #expect(presence == nil)
    }

    @Test
    func missingVehiclePositionGivesNoPresence() {
        let locations = [spot("home", alias: "Home", latitude: home.latitude, longitude: home.longitude)]
        #expect(ChargeLocationPresence.resolve(location: nil, locations: locations, previous: nil) == nil)
        #expect(ChargeLocationPresence.resolve(location: VehicleLocation(latitude: nil, longitude: nil),
                                               locations: locations, previous: nil) == nil)
    }

    @Test
    func sinceIsCarriedForwardWhileTheSameLocationStillMatches() {
        let locations = [spot("home", alias: "Home", latitude: home.latitude, longitude: home.longitude)]
        let first = ChargeLocationPresence(locationID: "home", alias: "Home",
                                           since: start, source: .proximity)
        let later = ChargeLocationPresence.resolve(
            location: position(offset(northMeters: 10), at: start.addingTimeInterval(900)),
            locations: locations, previous: first
        )
        #expect(later?.since == start)
    }

    @Test
    func sinceRestartsWhenThePresenceChangesLocation() {
        let locations = [spot("home", alias: "Home", latitude: home.latitude, longitude: home.longitude)]
        let previous = ChargeLocationPresence(locationID: "elsewhere", alias: "Elsewhere",
                                              since: start, source: .proximity)
        let arrivedAt = start.addingTimeInterval(3_600)
        let presence = ChargeLocationPresence.resolve(
            location: position(offset(northMeters: 0), at: arrivedAt),
            locations: locations, previous: previous
        )
        #expect(presence?.since == arrivedAt)
    }

    @Test
    func presenceIsDerivedInTheMergedStateAndNotCarriedFromCache() {
        var previous = vehicle(vin: "YSMPRESENCE", battery: 60)
        previous.energy.locations = [spot("home", alias: "Home", latitude: home.latitude, longitude: home.longitude)]
        previous.location = position(offset(northMeters: 0), at: start)
        previous.chargeLocationPresence = nil

        var incoming = vehicle(vin: "YSMPRESENCE", battery: 61)
        incoming.energy.locations = previous.energy.locations
        incoming.location = position(offset(northMeters: 5), at: start.addingTimeInterval(600))

        let merged = incoming.mergingLastKnown(from: previous, features: .default)
        #expect(merged.chargeLocationPresence?.alias == "Home")
        #expect(merged.chargeLocationPresence?.since == start.addingTimeInterval(600))

        let cached = merged.cacheableCopy
        #expect(cached.chargeLocationPresence == nil)
    }

    // MARK: - Cost by location

    private func session(
        _ id: String, location: String?, energy: Double, cost: Double?, currency: String? = nil,
        hoursAfterStart: Double = 0
    ) -> HistoricalChargingSession {
        let startedAt = start.addingTimeInterval(hoursAfterStart * 3_600)
        return HistoricalChargingSession(
            id: id, vin: "VIN", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(3_600),
            startSoc: 20, endSoc: 60, energyDeliveredKwh: energy, peakPowerKw: 50, averagePowerKw: 35,
            locationName: location, createdAt: startedAt, currencySymbol: currency, estimatedCost: cost
        )
    }

    @Test
    func costRowsGroupByPlaceAndAverageCostPerKwh() {
        let sessions = [
            session("a", location: "Home", energy: 10, cost: 20, currency: "kr"),
            session("b", location: "Home", energy: 30, cost: 66, currency: "kr", hoursAfterStart: 24),
            session("c", location: "Ionity", energy: 40, cost: 160, currency: "kr", hoursAfterStart: 48)
        ]
        let rows = HistoryInsights.locationCostRows(from: sessions, fallbackPricePerKwh: 2,
                                                    fallbackCurrency: "kr", unknownLabel: "Unknown location")
        #expect(rows.count == 2)
        let home = rows.first { $0.name == "Home" }
        #expect(home?.sessionCount == 2)
        #expect(home?.energyKwh == 40)
        #expect(home?.totalCost == 86)
        #expect(home?.averageCostPerKwh == 2.15)
        #expect(rows.first?.name == "Home")
    }

    @Test
    func costRowsNeverAddCurrenciesTogether() {
        let sessions = [
            session("a", location: "Border", energy: 10, cost: 20, currency: "kr"),
            session("b", location: "Border", energy: 10, cost: 3, currency: "€", hoursAfterStart: 24)
        ]
        let rows = HistoryInsights.locationCostRows(from: sessions, fallbackPricePerKwh: 2,
                                                    fallbackCurrency: "kr", unknownLabel: "Unknown location")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.sessionCount == 1 })
        #expect(rows.first { $0.currency == "kr" }?.totalCost == 20)
        #expect(rows.first { $0.currency == "€" }?.totalCost == 3)
    }

    @Test
    func unnamedSessionsCollapseIntoTheUnknownBucket() {
        let sessions = [
            session("a", location: nil, energy: 5, cost: 10, currency: "kr"),
            session("b", location: "  ", energy: 5, cost: 10, currency: "kr", hoursAfterStart: 24)
        ]
        let rows = HistoryInsights.locationCostRows(from: sessions, fallbackPricePerKwh: 2,
                                                    fallbackCurrency: "kr", unknownLabel: "Unknown location")
        #expect(rows.count == 1)
        #expect(rows.first?.name == "Unknown location")
        #expect(rows.first?.sessionCount == 2)
    }

    @Test
    func sessionsWithoutSavedPriceUseTheFallbackRate() {
        let sessions = [session("a", location: "Work", energy: 12, cost: nil)]
        let rows = HistoryInsights.locationCostRows(from: sessions, fallbackPricePerKwh: 1.5,
                                                    fallbackCurrency: "kr", unknownLabel: "Unknown location")
        #expect(rows.first?.totalCost == 18)
        #expect(rows.first?.currency == "kr")
    }

    @Test
    func averageIsNotReportedWithoutEnergy() {
        let sessions = [session("a", location: "Work", energy: 0, cost: 0, currency: "kr")]
        let rows = HistoryInsights.locationCostRows(from: sessions, fallbackPricePerKwh: 2,
                                                    fallbackCurrency: "kr", unknownLabel: "Unknown location")
        #expect(rows.first?.averageCostPerKwh == nil)
    }
}
