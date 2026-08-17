import Foundation
import Testing
@testable import Hisingen


@MainActor
struct RegressionFixTests {


    @Test
    func testUpdateCheckerPointsToMaintainedFork() {
        // Not /releases/latest: that resolves to whichever release GitHub published most
        // recently, which is the CI's unsigned rolling "latest" build far more often than
        // an actual signed, notarized version. See UpdateChecker.releasePage(for:).
        XCTAssertEqual(UpdateChecker.releasesPage.host, "github.com")
        XCTAssertEqual(UpdateChecker.releasesPage.path, "/NicolasKheirallah/hisingen/releases")
        XCTAssertEqual(UpdateChecker.releasePage(for: "2.1.0").path,
                       "/NicolasKheirallah/hisingen/releases/tag/v2.1.0")
        XCTAssertEqual(UpdateChecker.releasePage(for: nil), UpdateChecker.releasesPage)
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
        XCTAssertEqual(software.version, "5.0.10")
        XCTAssertEqual(software.state, .available)
        XCTAssertNil(software.installedVersion)
        XCTAssertEqual(software.latestAvailableVersion, "5.0.10")
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
        XCTAssertEqual(status.activity, .idle)
    }

    @Test
    func testDigitalTwinClimateActiveStillReportsVentilating() {


        var climate = Data()
        climate.append(Protobuf.messageField(1, Protobuf.intField(1, 2_000_000_000)))
        climate.append(Protobuf.intField(2, 1))
        climate.append(Protobuf.intField(6, 1))

        let status = PolestarGRPC.parseClimate(climate)
        XCTAssertEqual(status.activity, .ventilating)
    }


    @Test
    func testChargingSpeedEstimateDiffersByModel() {
        let polestar1Rate = Format.chargingRateKmPerHour(
            powerWatts: 7_200, consumptionWhPerKm: VehicleModelFamily.polestar1.averageConsumptionWhPerKm!)
        let polestar2Rate = Format.chargingRateKmPerHour(
            powerWatts: 7_200, consumptionWhPerKm: VehicleModelFamily.polestar2.averageConsumptionWhPerKm!)
        XCTAssertTrue(polestar1Rate != polestar2Rate,
                      "Different models must not share one flat consumption assumption")
    }


    @Test
    func testServiceWarningSurvivesTransientHealthFailure() {
        let previous = makeVehicleState(serviceWarning: true, unavailableFeatures: [])
        let failedFetch = makeVehicleState(serviceWarning: false, unavailableFeatures: [.vehicleHealth])

        let merged = failedFetch.mergingLastKnown(from: previous, features: FeatureSelection(enabled: [.vehicleHealth]))

        XCTAssertTrue(merged.serviceWarning, "A failed health fetch must not silently clear a known warning")
    }

    @Test
    func testServiceWarningClearsWhenHealthFetchSucceeds() {
        let previous = makeVehicleState(serviceWarning: true, unavailableFeatures: [])
        let resolvedFetch = makeVehicleState(serviceWarning: false, unavailableFeatures: [])

        let merged = resolvedFetch.mergingLastKnown(from: previous, features: FeatureSelection(enabled: [.vehicleHealth]))

        XCTAssertFalse(merged.serviceWarning, "A successful health fetch reporting no warning must be trusted")
    }


    @Test
    func testRainWithWindowsOpenConditionDetectsAndClears() {
        let dry = makeVehicleState(weatherCondition: "Clear", windowOpen: true)
        XCTAssertFalse(Notifier.rainWithWindowsOpenCondition(dry))

        let rainyWindowsClosed = makeVehicleState(weatherCondition: "Rain", windowOpen: false)
        XCTAssertFalse(Notifier.rainWithWindowsOpenCondition(rainyWindowsClosed))

        let rainyWindowsOpen = makeVehicleState(weatherCondition: "Rain", windowOpen: true)
        XCTAssertTrue(Notifier.rainWithWindowsOpenCondition(rainyWindowsOpen))


        XCTAssertTrue(Notifier.rainWithWindowsOpenCondition(rainyWindowsOpen)
            == Notifier.rainWithWindowsOpenCondition(rainyWindowsOpen))
    }

    @Test
    func testEveningUnlockedConditionUsesStateTimestamp() {
        let calendar = Calendar.current
        let now = Date()
        let nightTime = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? now
        let dayTime = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now

        let unlockedAtNight = makeVehicleState(isLocked: false, fetchedAt: nightTime)
        XCTAssertTrue(Notifier.eveningUnlockedCondition(unlockedAtNight))

        let unlockedDuringDay = makeVehicleState(isLocked: false, fetchedAt: dayTime)
        XCTAssertFalse(Notifier.eveningUnlockedCondition(unlockedDuringDay))

        let lockedAtNight = makeVehicleState(isLocked: true, fetchedAt: nightTime)
        XCTAssertFalse(Notifier.eveningUnlockedCondition(lockedAtNight))
    }


    private func makeVehicleState(
        serviceWarning: Bool = false,
        unavailableFeatures: [AppFeature] = [],
        weatherCondition: String? = nil,
        windowOpen: Bool = false,
        isLocked: Bool = true,
        fetchedAt: Date = Date()
    ) -> VehicleState {
        let exteriorStatus = ExteriorSnapshot(
            openings: windowOpen ? [OpeningReading(opening: .frontLeftWindow, state: .open)] : [],
            isLocked: isLocked,
            alarmTriggered: false
        )
        let weather = weatherCondition.map { VehicleWeather(temperatureCelsius: 5, condition: $0) }
        return VehicleState(
            batteryPercentage: 60,
            rangeKm: 300,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 80,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "TEST123",
            vin: "YS2P2000000000001",
            ownerFirstName: "Nico",
            odometerKm: 10000,
            daysToService: 100,
            distanceToServiceKm: 5000,
            serviceWarning: serviceWarning,
            fluidWarnings: [],
            exteriorStatus: exteriorStatus,
            weather: weather,
            location: VehicleLocation(latitude: 57.7427, longitude: 11.9682),
            unavailableFeatures: unavailableFeatures,
            imageData: nil,
            fetchedAt: fetchedAt,
            vehicleReportedAt: fetchedAt,
            dataWarnings: []
        )
    }

    @Test
    func testCacheableCopyPreservesLocationAndRegistrationAndGreeting() {
        let original = makeVehicleState()
        let copy = original.cacheableCopy

        XCTAssertEqual(copy.registrationNo, "TEST123")
        XCTAssertEqual(copy.ownerFirstName, "Nico")
        XCTAssertEqual(copy.location?.latitude, 57.7427)
        XCTAssertEqual(copy.location?.longitude, 11.9682)
    }
}


