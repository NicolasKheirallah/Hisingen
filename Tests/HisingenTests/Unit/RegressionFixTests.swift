import Foundation
import Testing
@testable import Hisingen


@MainActor
struct RegressionFixTests {

    @Test
    func testLocationURLsRequireHTTPS() {
        let mapsURL = StatusItemController.appleMapsURL(
            latitude: 57.7089,
            longitude: 11.9746,
            label: "Polestar"
        )
        #expect(mapsURL?.scheme == "https")
        #expect(mapsURL?.host == "maps.apple.com")

        let weatherURL = OpenMeteoWeatherClient.openMeteoURL(latitude: 57.7089, longitude: 11.9746)
        #expect(weatherURL?.scheme == "https")
        #expect(weatherURL?.host == "api.open-meteo.com")
    }


    @Test
    func testSoftwareVersionRepresentsAvailableUpdateNotInstalledVersion() {


        var description = Data()
        description.append(Protobuf.stringField(1, "Software update"))
        var payload = Data()
        payload.append(Protobuf.messageField(2, description))
        payload.append(Protobuf.intField(4, 15))
        payload.append(Protobuf.stringField(6, "5.0.10"))
        let software = PolestarGRPC.parseSoftware(payload)
        #expect(software.version == "5.0.10")
        #expect(software.state == .available)
        #expect(software.installedVersion == nil)
        #expect(software.latestAvailableVersion == "5.0.10")
    }


    @Test
    func testDigitalTwinClimateOffIsNeverReportedAsVentilatingOrHeating() {


        var climate = Data()
        climate.append(Protobuf.messageField(1, Protobuf.intField(1, 2_000_000_000)))
        climate.append(Protobuf.intField(2, 0))
        climate.append(Protobuf.intField(6, 1))
        climate.append(Protobuf.doubleField(7, 8.0))
        climate.append(Protobuf.doubleField(8, 21.0))

        let status = PolestarGRPC.parseClimate(climate)
        #expect(status.activity == .idle)
    }

    @Test
    func testDigitalTwinClimateActiveDoesNotMisreportVentilating() {
        // Live-verified 2026-09-11: wire field 6 = 2 throughout a real *heating* session, and
        // 3 while idle – it is an unresolved activity enum, not a ventilation flag. An active
        // session with no temperature pair must report plain .active, never .ventilating.
        var climate = Data()
        climate.append(Protobuf.messageField(1, Protobuf.intField(1, 2_000_000_000)))
        climate.append(Protobuf.intField(2, 1))
        climate.append(Protobuf.intField(6, 2))

        let status = PolestarGRPC.parseClimate(climate)
        #expect(status.activity == .active)
    }


    @Test
    func testChargingSpeedEstimateDiffersByModel() {
        let polestar1Rate = Format.chargingRateKmPerHour(
            powerWatts: 7_200, consumptionWhPerKm: VehicleModelFamily.polestar1.averageConsumptionWhPerKm!)
        let polestar2Rate = Format.chargingRateKmPerHour(
            powerWatts: 7_200, consumptionWhPerKm: VehicleModelFamily.polestar2.averageConsumptionWhPerKm!)
        #expect(polestar1Rate != polestar2Rate, "Different models must not share one flat consumption assumption")
    }


    @Test
    func testServiceWarningSurvivesTransientHealthFailure() {
        let previous = makeVehicleState(serviceWarning: true, unavailableFeatures: [])
        let failedFetch = makeVehicleState(serviceWarning: false, unavailableFeatures: [.vehicleHealth])

        let merged = failedFetch.mergingLastKnown(from: previous, features: FeatureSelection(enabled: [.vehicleHealth]))

        #expect(merged.maintenance.service.serviceWarning, "A failed health fetch must not silently clear a known warning")
    }

    @Test
    func testServiceWarningClearsWhenHealthFetchSucceeds() {
        let previous = makeVehicleState(serviceWarning: true, unavailableFeatures: [])
        let resolvedFetch = makeVehicleState(serviceWarning: false, unavailableFeatures: [])

        let merged = resolvedFetch.mergingLastKnown(from: previous, features: FeatureSelection(enabled: [.vehicleHealth]))

        #expect(!(merged.maintenance.service.serviceWarning), "A successful health fetch reporting no warning must be trusted")
    }


    @Test
    func testRainWithWindowsOpenConditionDetectsAndClears() {
        let dry = makeVehicleState(weatherCondition: "Clear", windowOpen: true)
        #expect(!(Notifier.rainWithWindowsOpenCondition(dry)))

        let rainyWindowsClosed = makeVehicleState(weatherCondition: "Rain", windowOpen: false)
        #expect(!(Notifier.rainWithWindowsOpenCondition(rainyWindowsClosed)))

        let rainyWindowsOpen = makeVehicleState(weatherCondition: "Rain", windowOpen: true)
        #expect(Notifier.rainWithWindowsOpenCondition(rainyWindowsOpen))
    }

    @Test
    func testEveningUnlockedConditionUsesStateTimestamp() {
        let calendar = Calendar.current
        let now = Date()
        let nightTime = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? now
        let dayTime = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now

        let unlockedAtNight = makeVehicleState(isLocked: false, fetchedAt: nightTime)
        #expect(Notifier.eveningUnlockedCondition(unlockedAtNight))

        let unlockedDuringDay = makeVehicleState(isLocked: false, fetchedAt: dayTime)
        #expect(!(Notifier.eveningUnlockedCondition(unlockedDuringDay)))

        let lockedAtNight = makeVehicleState(isLocked: true, fetchedAt: nightTime)
        #expect(!(Notifier.eveningUnlockedCondition(lockedAtNight)))
    }


    private func makeVehicleState(
        serviceWarning: Bool = false,
        unavailableFeatures: [AppFeature] = [],
        weatherCondition: String? = nil,
        windowOpen: Bool = false,
        isLocked: Bool = true,
        fetchedAt: Date = Date()
    ) -> VehicleState {
        // TESTS-12: thin wrapper over the shared TestSupport fixture builder.
        let exteriorStatus = ExteriorSnapshot(
            openings: windowOpen ? [OpeningReading(opening: .frontLeftWindow, state: .open)] : [],
            isLocked: isLocked,
            alarmTriggered: false
        )
        let weather = weatherCondition.map { VehicleWeather(temperatureCelsius: 5, condition: $0) }
        return vehicle(
            vin: "YS2P2000000000001", battery: 60, rangeKm: 300,
            chargingType: .none,
            modelYear: "2024",
            registrationNo: "TEST123", ownerFirstName: "Nico",
            odometerKm: 10_000, daysToService: 100, distanceToServiceKm: 5_000,
            serviceWarning: serviceWarning,
            exteriorStatus: exteriorStatus,
            weather: weather,
            location: VehicleLocation(latitude: 57.7427, longitude: 11.9682),
            unavailableFeatures: unavailableFeatures,
            fetchedAt: fetchedAt, reportedAt: fetchedAt
        )
    }

    @Test
    func testCacheableCopyDropsLocationAndPersonalIdentity() {
        let original = makeVehicleState()
        let copy = original.cacheableCopy

        #expect(copy.identity.registrationNo == nil)
        #expect(copy.identity.ownerFirstName == nil)
        #expect(copy.location == nil)
    }
}
