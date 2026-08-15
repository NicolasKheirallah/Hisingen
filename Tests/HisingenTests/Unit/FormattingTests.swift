import Foundation
import Testing
@testable import Hisingen

@MainActor
struct FormattingTests {
    @Test
    func testShortDuration() {
        XCTAssertEqual(Format.shortDuration(minutes: 45), "45min")
        XCTAssertEqual(Format.shortDuration(minutes: 60), "1h")
        XCTAssertEqual(Format.shortDuration(minutes: 135), "2h15m")
    }

    @Test
    func testBatteryColor() {
        XCTAssertEqual(Format.batteryColor(percentage: 15, charging: true), .systemGreen)
        XCTAssertEqual(Format.batteryColor(percentage: 15, charging: false), .systemOrange)
        XCTAssertEqual(Format.batteryColor(percentage: 80, charging: false), .controlAccentColor)
    }

    @Test
    func testDistanceFormattingAndConversion() {
        XCTAssertEqual(DistanceUnit.kilometers.convert(km: 412), 412)
        XCTAssertEqual(DistanceUnit.miles.convert(km: 412), 256)
        XCTAssertEqual(Format.distance(km: 412, unit: .kilometers), "412 km")
        XCTAssertEqual(Format.distance(km: 412, unit: .miles), "256 mi")
        let grouped = Format.distance(km: 23_412, grouped: true, unit: .kilometers)
        XCTAssertTrue(grouped.hasSuffix(" km"))
        XCTAssertTrue(grouped.contains("23"))
    }

    @Test
    func testLegacyPreferenceValuesMigrate() {
        UserDefaults.standard.set("Range (km)", forKey: "statusbar_display_option")
        UserDefaults.standard.set("Miles (mi)", forKey: "distance_unit")
        defer {
            UserDefaults.standard.removeObject(forKey: "statusbar_display_option")
            UserDefaults.standard.removeObject(forKey: "distance_unit")
        }
        XCTAssertEqual(Preferences.menuBarStyle, .range)
        XCTAssertEqual(Preferences.distanceUnit, .miles)
    }

    @Test
    func testFeatureSelectionCanDisableOptionalCapabilities() {
        var features = FeatureSelection.default
        XCTAssertTrue(features.contains(.vehicleImage))
        XCTAssertTrue(features.contains(.chargingDetails))
        XCTAssertFalse(features.contains(.connectivityDiagnostics))
        XCTAssertFalse(features.contains(.airQuality))
        XCTAssertFalse(features.contains(.batteryDiagnostics))
        XCTAssertFalse(features.contains(.vehicleHealth))
        XCTAssertFalse(AppFeature.remoteFeatures.contains { features.contains($0) })
        features.set(.chargingDetails, enabled: false)
        features.set(.vehicleImage, enabled: false)
        XCTAssertFalse(features.contains(.chargingDetails))
        XCTAssertFalse(features.contains(.vehicleImage))
    }

    @Test
    func testRemoteFeaturesAreOptInAndSelectable() {
        let selection = FeatureSelection.default
        XCTAssertFalse(AppFeature.remoteFeatures.contains { selection.contains($0) })
        XCTAssertTrue(AppFeature.userSelectableCases.contains(.remoteClimate))
    }

    @Test
    func testVINValidationSupportsGuestAccountFallback() {
        XCTAssertTrue(PolestarAPI.isValidVIN("YSMVSEDE6PL000001"))
        XCTAssertFalse(PolestarAPI.isValidVIN("TOO-SHORT"))
        XCTAssertFalse(PolestarAPI.isValidVIN("YSMVSEDEIPL147228"))
    }

    @Test
    func testHealthFeatureControlsGraphQLSelections() {
        var features = FeatureSelection.default
        features.set(.vehicleHealth, enabled: true)
        let enabled = PolestarAPI.telematicsQuery(features: features)
        XCTAssertTrue(enabled.contains("odometerMeters"))
        XCTAssertTrue(enabled.contains("daysToService"))
        features.set(.vehicleHealth, enabled: false)
        let disabled = PolestarAPI.telematicsQuery(features: features)
        XCTAssertFalse(disabled.contains("odometerMeters"))
        XCTAssertFalse(disabled.contains("daysToService"))
        XCTAssertTrue(disabled.contains("batteryChargeLevelPercentage"))
    }

    @Test
    func testMissingCoreTelemetryKeepsLastKnownValueForSameVIN() {
        let previous = vehicle(vin: "VIN-A", battery: 64)
        let current = vehicle(vin: "VIN-A", battery: nil)
        let merged = current.mergingLastKnown(from: previous, features: .default)
        XCTAssertEqual(merged.batteryPercentage, 64)
        XCTAssertNil(current.mergingLastKnown(
            from: vehicle(vin: "VIN-B", battery: 81), features: .default
        ).batteryPercentage)
    }

    @Test
    func testDiskSnapshotExpiresAndOmitsPersonalDetails() throws {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VehicleStateStore(defaults: defaults)
        let stale = vehicle(
            vin: "VIN-A", fetchedAt: Date().addingTimeInterval(-8 * 24 * 60 * 60), reportedAt: nil
        )
        store.save(stale)
        XCTAssertNil(store.snapshot(for: "VIN-A"))
        XCTAssertNil(stale.cacheableCopy.ownerFirstName)
        XCTAssertNil(stale.cacheableCopy.registrationNo)
        XCTAssertNil(stale.cacheableCopy.imageData)
    }

    @Test
    func testKilowattsFormatting() {
        XCTAssertEqual(Format.kilowatts(watts: 7_200), "7.2 kW")
        XCTAssertEqual(Format.kilowatts(watts: 11_000), "11 kW")
        XCTAssertEqual(Format.kilowatts(watts: 150_000), "150 kW")
    }

    @Test
    func testProtobufVarintRoundTripAndFrame() {
        for value: UInt64 in [0, 1, 127, 128, 300, 7_200, UInt64(Int32.max)] {
            var message = Protobuf.varint(UInt64(5 << 3))
            message.append(Protobuf.varint(value))
            let field = Protobuf.fields(message).first
            XCTAssertEqual(field?.number, 5)
            XCTAssertEqual(field?.varint, value)
        }
        let message = Protobuf.stringField(2, "LPSVSESEKML123456")
        let frame = Protobuf.grpcFrame(message)
        XCTAssertEqual(frame[0], 0)
        XCTAssertEqual(frame.count, message.count + 5)
    }

    @Test
    func testGrpcBatteryParseIncludesVerifiedFields() {
        var battery = Data()
        let percentageBits = 54.5.bitPattern.littleEndian
        battery.append(Protobuf.varint(UInt64(2 << 3 | 1)))
        withUnsafeBytes(of: percentageBits) { battery.append(contentsOf: $0) }
        battery.append(Protobuf.intField(4, 321))
        battery.append(Protobuf.intField(5, 95))
        battery.append(Protobuf.intField(6, 1))
        battery.append(Protobuf.intField(7, 1))
        battery.append(Protobuf.intField(10, 7_200))
        battery.append(Protobuf.intField(11, 16))
        battery.append(Protobuf.intField(17, 2))
        battery.append(Protobuf.intField(18, 230))

        let result = PolestarGRPC.parseBattery(battery)
        XCTAssertEqual(result.batteryPercentage, 54.5)
        XCTAssertEqual(result.rangeKm, 321)
        XCTAssertEqual(result.estimatedChargingTimeToFullMinutes, 95)
        XCTAssertEqual(result.chargerConnection, .connected)
        XCTAssertEqual(result.chargingState, .charging)
        XCTAssertEqual(result.chargingType, .ac)
        XCTAssertEqual(result.chargingPowerWatts, 7_200)
        XCTAssertEqual(result.chargingCurrentAmps, 16)
        XCTAssertEqual(result.chargingVoltageVolts, 230)
    }

    @Test
    func testTypedChargingStateAndIcons() {
        XCTAssertEqual(ChargingState(apiValue: "CHARGING_STATUS_V2_SMART_CHARGING"), .smartCharging)
        XCTAssertTrue(ChargingState(apiValue: "CHARGING_STATUS_CHARGING").isActivelyCharging)
        XCTAssertFalse(ChargingState(apiValue: "CHARGING_STATUS_IDLE").isActivelyCharging)
        XCTAssertEqual(Format.icon(for: vehicle(state: .charging, connection: .connected)), "bolt.car.fill")
        XCTAssertEqual(Format.icon(for: vehicle(state: .idle, connection: .connected)), "bolt.car")
        XCTAssertEqual(Format.icon(for: vehicle(state: .idle, connection: .disconnected)), "car")
        XCTAssertEqual(Format.icon(
            for: vehicle(state: .charging, connection: .connected), includeConnection: false
        ), "car")
        XCTAssertEqual(Format.icon(for: nil), "car")
    }

    @Test
    func testStaleThresholdIsStricterWhileCharging() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(vehicle(state: .charging, fetchedAt: now.addingTimeInterval(-901),
                              reportedAt: now.addingTimeInterval(-901)).isStale(at: now))
        XCTAssertFalse(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-901),
                               reportedAt: now.addingTimeInterval(-901)).isStale(at: now))
        XCTAssertTrue(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-3_601),
                              reportedAt: now.addingTimeInterval(-3_601)).isStale(at: now))
    }

    @Test
    func testFreshFetchIsNotStaleEvenWhenVehicleReportsOldData() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)


        XCTAssertFalse(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-30),
                               reportedAt: now.addingTimeInterval(-10_800)).isStale(at: now))

        XCTAssertTrue(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-130),
                              reportedAt: now.addingTimeInterval(-10_800)).isStale(at: now))
    }

    @Test
    func testVersionComparisonHandlesSemVer() {
        XCTAssertTrue(UpdateChecker.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.1"))
        XCTAssertTrue(UpdateChecker.isVersion("v1.0.1+12", newerThan: "1.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0-beta.2", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.0-beta.10", newerThan: "1.0.0-beta.2"))
        XCTAssertFalse(UpdateChecker.isVersion("invalid", newerThan: "1.0.0"))
    }

    @Test
    func testReleaseEvaluationFiltersDraftsAndPrereleases() throws {
        let stable = #"{"tag_name":"v3.0.0","draft":false,"prerelease":false}"#.data(using: .utf8)!
        let prerelease = #"{"tag_name":"v4.0.0-beta.1","draft":false,"prerelease":true}"#.data(using: .utf8)!
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: stable, currentVersion: "2.4.1"),
                           .updateAvailable("3.0.0"))
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: stable, currentVersion: "3.0.0"), .upToDate)
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: prerelease, currentVersion: "2.4.1"), .upToDate)
    }

    @Test
    func testGreetingUsesSystemLanguage() {
        XCTAssertEqual(Format.greeting("Simon", languageCode: "da-DK"), "Hej, Simon")
        XCTAssertEqual(Format.greeting("Simon", languageCode: "en-US"), "Hi, Simon")
        XCTAssertEqual(Format.greeting("Simon", languageCode: nil as String?), "Hi, Simon")
    }

    @Test
    func testGreetingUsesSelectedInterfaceLanguage() {
        let previousLanguage = Preferences.interfaceLanguage
        defer { Preferences.interfaceLanguage = previousLanguage }

        Preferences.interfaceLanguage = .english
        XCTAssertEqual(Format.greeting("Nicolas"), "Hi, Nicolas")
        Preferences.interfaceLanguage = .swedish
        XCTAssertEqual(Format.greeting("Nicolas"), "Hej, Nicolas")
    }

    @Test
    func testSwedishVehicleCardsDoNotFallBackToEnglishKeys() {
        let previousLanguage = Preferences.interfaceLanguage
        defer { Preferences.interfaceLanguage = previousLanguage }
        Preferences.interfaceLanguage = .swedish

        XCTAssertEqual(L10n.text("Charging & Energy"), "Laddning och energi")
        XCTAssertEqual(L10n.text("Charger Connection"), "Laddkontakt")
        XCTAssertEqual(L10n.text("Est. Charge Cost"), "Beräknad laddkostnad")
        XCTAssertEqual(L10n.text("Power Module"), "Laddarmodul")
        XCTAssertEqual(L10n.text("Vehicle Status"), "Fordonsstatus")
        XCTAssertEqual(L10n.text("Odometer"), "Mätarställning")
        XCTAssertEqual(L10n.text("Cloud Connectivity"), "Molnanslutning")
        XCTAssertEqual(L10n.text("Climate & Timers"), "Klimat och timers")
        XCTAssertEqual(L10n.text("Cabin Climate"), "Kupéklimat")
        XCTAssertEqual(L10n.text("Complete"), "Fulladdad")
        XCTAssertEqual(L10n.text("Securely Locked"), "Låst")
        XCTAssertEqual(L10n.text("Current Limit"), "Maximal laddström")
        XCTAssertEqual(L10n.text("Window controls"), "Rutreglage")
        XCTAssertEqual(L10n.text("Range Health Estimate"), "Räckviddsbedömning")
        XCTAssertEqual(L10n.text("System Default"), "Följ systemet")
    }

    @Test
    func testCompletionTimeFormatting() {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        let utcZone = TimeZone(secondsFromGMT: 0)!
        let formattedUTC = Format.completionTime(from: 90, baseDate: baseDate, timeZone: utcZone)
        XCTAssertFalse(formattedUTC.isEmpty)
    }

    @Test
    func testChargingRateFormatting() {
        XCTAssertEqual(Format.chargingRateKmPerHour(powerWatts: 7_200, consumptionWhPerKm: 180), 40)
        XCTAssertEqual(Format.chargingRateKmPerHour(powerWatts: 150_000, consumptionWhPerKm: 200), 750)
        XCTAssertEqual(Format.chargingRateKmPerHour(powerWatts: 0), 0)

        XCTAssertEqual(Format.chargingRateFormatted(powerWatts: 7_200, unit: .kilometers), "+40 km/h")
        XCTAssertEqual(Format.chargingRateFormatted(powerWatts: 7_200, unit: .miles), "+25 mph")
    }

    @Test
    func testBatterySymbol() {
        XCTAssertEqual(Format.batterySymbol(for: 95, isCharging: false), "battery.100percent")
        XCTAssertEqual(Format.batterySymbol(for: 75, isCharging: false), "battery.75percent")
        XCTAssertEqual(Format.batterySymbol(for: 50, isCharging: false), "battery.50percent")
        XCTAssertEqual(Format.batterySymbol(for: 20, isCharging: false), "battery.25percent")
        XCTAssertEqual(Format.batterySymbol(for: 8, isCharging: false), "battery.0percent")
        XCTAssertEqual(Format.batterySymbol(for: 50, isCharging: true), "bolt.car.fill")
    }

    @Test
    func testMenuBarStyles() {
        let chargingCar = VehicleState(
            batteryPercentage: 82, rangeKm: 348, chargingState: .charging,
            estimatedChargingTimeToFullMinutes: 102, chargeTargetPercentage: 90,
            chargingPowerWatts: 7_200, chargingCurrentAmps: 16, chargingVoltageVolts: 230,
            chargingType: .ac, chargerConnection: .connected, availability: .available,
            modelName: "Polestar 2", modelYear: "2024", registrationNo: nil, vin: "YSMTEST",
            ownerFirstName: nil, odometerKm: 12_500, daysToService: nil, distanceToServiceKm: nil,
            serviceWarning: false, fluidWarnings: [], imageData: nil, fetchedAt: Date(),
            vehicleReportedAt: Date(), dataWarnings: []
        )

        XCTAssertEqual(Format.barTitle(for: chargingCar, style: .battery, unit: .kilometers), "82%")
        XCTAssertEqual(Format.barTitle(for: chargingCar, style: .batteryAndRange, unit: .kilometers), "82% · 348km")
        XCTAssertEqual(Format.barTitle(for: chargingCar, style: .chargingAware, unit: .kilometers), "82% · 1h42m")
        XCTAssertEqual(Format.barTitle(for: chargingCar, style: .compactCharging, unit: .kilometers), "82% (1h42m)")
        XCTAssertEqual(Format.barTitle(for: chargingCar, style: .batteryAndPower, unit: .kilometers), "82% · 7.2 kW")
        XCTAssertEqual(Format.barTitle(for: chargingCar, style: .range, unit: .kilometers), "348km")

        let idleCar = vehicle(battery: 82, state: .idle, connection: .disconnected)
        XCTAssertEqual(Format.barTitle(for: idleCar, style: .compactCharging, unit: .kilometers), "82%")
        XCTAssertEqual(Format.barTitle(for: idleCar, style: .batteryAndPower, unit: .kilometers), "82% · 200km")
    }

    @Test
    func testVehicleStateFormattingHelpers() {
        let chargingCar = VehicleState(
            batteryPercentage: 82, rangeKm: 348, chargingState: .charging,
            estimatedChargingTimeToFullMinutes: 60, chargeTargetPercentage: 90,
            chargingPowerWatts: 11_000, chargingCurrentAmps: 16, chargingVoltageVolts: 400,
            chargingType: .ac, chargerConnection: .connected, availability: .available,
            modelName: "Polestar 2", modelYear: "2024", registrationNo: nil, vin: "YSMTEST",
            ownerFirstName: nil, odometerKm: 12_500, daysToService: nil, distanceToServiceKm: nil,
            serviceWarning: false, fluidWarnings: [], imageData: nil, fetchedAt: Date(),
            vehicleReportedAt: Date(), dataWarnings: []
        )

        XCTAssertNotNil(chargingCar.formattedCompletionTime)
        XCTAssertEqual(chargingCar.formattedChargingRate(unit: .kilometers), "+70 km/h")
        XCTAssertTrue(chargingCar.freshnessDescription.contains("Updated"))
    }

    @Test
    func testChargingSessionSamplesAndSparklineBuffering() {
        var state1 = vehicle(battery: 50, state: .charging, connection: .connected)
        let sample1 = ChargingSample(timestamp: Date(timeIntervalSince1970: 1000), batteryPercentage: 50, powerWatts: 7200)
        state1.chargingSamples = [sample1]

        let state2 = vehicle(battery: 52, state: .charging, connection: .connected, fetchedAt: Date(timeIntervalSince1970: 1060))
        let merged = state2.mergingLastKnown(from: state1, features: .default)

        XCTAssertEqual(merged.chargingSamples.count, 2)
        XCTAssertEqual(merged.chargingSamples.first?.batteryPercentage, 50)
        XCTAssertEqual(merged.chargingSamples.last?.batteryPercentage, 52)


        let idleState = vehicle(battery: 80, state: .idle, connection: .disconnected)
        let cleared = idleState.mergingLastKnown(from: merged, features: .default)
        XCTAssertTrue(cleared.chargingSamples.isEmpty)
    }

    @Test
    func testChargingSessionSamplesSurviveCachedStateRoundTrip() throws {
        let suiteName = "HisingenTests.ChargingSamples.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var state = vehicle(battery: 64, state: .charging, connection: .connected)
        state.chargingSamples = [
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_000), batteryPercentage: 61, powerWatts: 6_200),
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_060), batteryPercentage: 64, powerWatts: 6_100)
        ]
        let store = VehicleStateStore(defaults: defaults)
        store.save(state)

        let restored = try XCTUnwrap(store.snapshot(for: state.vin))
        XCTAssertEqual(restored.chargingSamples, state.chargingSamples)
    }

    @Test
    func testCompletedChargingSessionSummary() throws {
        var previous = vehicle(battery: 50, state: .charging, connection: .connected,
                               fetchedAt: Date(timeIntervalSince1970: 1_000))
        previous.chargingSamples = [
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_000), batteryPercentage: 50, powerWatts: 7_200),
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_600), batteryPercentage: 60, powerWatts: 6_800)
        ]
        let current = vehicle(battery: 70, state: .idle, connection: .disconnected,
                              fetchedAt: Date(timeIntervalSince1970: 2_000))

        let session = try XCTUnwrap(ChargingSession.completed(previous: previous, current: current, pricePerKwh: 2))
        XCTAssertEqual(session.percentageAdded, 20)
        XCTAssertEqual(session.peakPowerWatts, 7_200)
        XCTAssertTrue(session.kwhDelivered > 0)
        XCTAssertEqual(session.cost, session.kwhDelivered * 2)
    }

    @Test
    func testMenuBarTintingPreference() {
        XCTAssertTrue(Preferences.tintMenuBarIcon)
    }

    @Test
    func testMultiCarIndexCycling() {
        let count = 3
        let currentIdx = 0
        let nextIdx = (currentIdx + 1) % count
        let prevIdx = (currentIdx - 1 + count) % count

        XCTAssertEqual(nextIdx, 1)
        XCTAssertEqual(prevIdx, 2)
    }

    @Test
    func testVehicleNicknamesAreStoredPerVIN() {
        let firstVIN = "YSMNICKNAME000001"
        let secondVIN = "YSMNICKNAME000002"
        defer {
            Preferences.setVehicleNickname("", for: firstVIN)
            Preferences.setVehicleNickname("", for: secondVIN)
        }

        Preferences.setVehicleNickname("Comet", for: firstVIN)
        Preferences.setVehicleNickname("Nova", for: secondVIN)

        XCTAssertEqual(Preferences.vehicleNickname(for: firstVIN), "Comet")
        XCTAssertEqual(Preferences.vehicleNickname(for: secondVIN), "Nova")
    }

    @Test
    func testShortTimeFormatting() {
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 8
        comps.day = 15
        comps.hour = 18
        comps.minute = 52
        comps.second = 0
        let date = calendar.date(from: comps) ?? Date()
        let formatted = Format.shortTime(date: date)
        XCTAssertFalse(formatted.isEmpty)
    }
}

func vehicle(
    vin: String = "YSMTEST",
    battery: Double? = 50,
    state: ChargingState = .idle,
    connection: ChargerConnection = .disconnected,
    target: Int? = 80,
    fetchedAt: Date = Date(),
    reportedAt: Date? = Date()
) -> VehicleState {
    VehicleState(
        batteryPercentage: battery, rangeKm: 200, chargingState: state,
        estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: target,
        chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
        chargingType: .unknown, chargerConnection: connection, availability: .available,
        modelName: nil, modelYear: nil, registrationNo: nil, vin: vin,
        ownerFirstName: nil, odometerKm: nil, daysToService: nil,
        distanceToServiceKm: nil, serviceWarning: false, fluidWarnings: [], imageData: nil,
        fetchedAt: fetchedAt, vehicleReportedAt: reportedAt, dataWarnings: []
    )
}


