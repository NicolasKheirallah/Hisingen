import Foundation
import Testing
@testable import Hisingen

@MainActor
struct FormattingTests {
    /// Isolated preference store per test — the dead `Preferences` global (deleted) wrote to
    /// `UserDefaults.standard` and leaked state across runs on developer machines.
    private func makeStore() throws -> (store: PreferencesStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (PreferencesStore(defaults: defaults), defaults, suiteName)
    }

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
    func testLegacyPreferenceValuesMigrate() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Range (km)", forKey: "statusbar_display_option")
        defaults.set("Miles (mi)", forKey: "distance_unit")
        XCTAssertEqual(store.menuBarStyle, .range)
        XCTAssertEqual(store.distanceUnit, .miles)
    }

    @Test
    func testVehicleModelBadgePositionPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.vehicleModelBadgePosition, .inlineHeader)
        store.vehicleModelBadgePosition = .topRightOverlay
        XCTAssertEqual(store.vehicleModelBadgePosition, .topRightOverlay)
        store.vehicleModelBadgePosition = .topLeftOverlay
        XCTAssertEqual(store.vehicleModelBadgePosition, .topLeftOverlay)
        store.vehicleModelBadgePosition = .subheadline
        XCTAssertEqual(store.vehicleModelBadgePosition, .subheadline)
        store.vehicleModelBadgePosition = .hidden
        XCTAssertEqual(store.vehicleModelBadgePosition, .hidden)
        store.vehicleModelBadgePosition = .inlineHeader
        XCTAssertEqual(store.vehicleModelBadgePosition, .inlineHeader)
    }

    @Test
    func testRegistrationBadgePositionPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.registrationBadgePosition, .belowGreeting)
        store.registrationBadgePosition = .platePill
        XCTAssertEqual(store.registrationBadgePosition, .platePill)
        store.registrationBadgePosition = .inlineHeader
        XCTAssertEqual(store.registrationBadgePosition, .inlineHeader)
        store.registrationBadgePosition = .topRightOverlay
        XCTAssertEqual(store.registrationBadgePosition, .topRightOverlay)
        store.registrationBadgePosition = .topLeftOverlay
        XCTAssertEqual(store.registrationBadgePosition, .topLeftOverlay)
        store.registrationBadgePosition = .hidden
        XCTAssertEqual(store.registrationBadgePosition, .hidden)
        store.registrationBadgePosition = .belowGreeting
        XCTAssertEqual(store.registrationBadgePosition, .belowGreeting)
    }

    @Test
    func testVehicleLabelFormatPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(store.vehicleLabelFormat, .modelAndYear)
        store.vehicleLabelFormat = .registration
        XCTAssertEqual(store.vehicleLabelFormat, .registration)
        store.vehicleLabelFormat = .nickname
        XCTAssertEqual(store.vehicleLabelFormat, .nickname)
        store.vehicleLabelFormat = .modelOnly
        XCTAssertEqual(store.vehicleLabelFormat, .modelOnly)
        store.vehicleLabelFormat = .nicknameAndRegistration
        XCTAssertEqual(store.vehicleLabelFormat, .nicknameAndRegistration)
        store.vehicleLabelFormat = .registrationAndModel
        XCTAssertEqual(store.vehicleLabelFormat, .registrationAndModel)
        store.vehicleLabelFormat = .modelAndYear
        XCTAssertEqual(store.vehicleLabelFormat, .modelAndYear)
    }

    @Test
    func testFormattedVehicleTitle() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let testVIN = "YS2TEST1234567890"
        store.setVehicleNickname("Silver Comet", for: testVIN)
        defer {
            store.setVehicleNickname("", for: testVIN)
        }

        // Test Registration Format
        let regTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .registration
        )
        XCTAssertEqual(regTitle, "ZCJ 06G")

        // Test Nickname Format
        let nickTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .nickname
        )
        XCTAssertEqual(nickTitle, "Silver Comet")

        // Test Model & Year Format
        let modelYrTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .modelAndYear
        )
        XCTAssertEqual(modelYrTitle, "Polestar 2 · 2024")

        // Test Model Only Format
        let modelOnlyTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .modelOnly
        )
        XCTAssertEqual(modelOnlyTitle, "Polestar 2")

        // Test Nickname & Registration Format
        let nickAndRegTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .nicknameAndRegistration
        )
        XCTAssertEqual(nickAndRegTitle, "Silver Comet (ZCJ 06G)")

        // Test Registration & Model Format
        let regAndModelTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .registrationAndModel
        )
        XCTAssertEqual(regAndModelTitle, "ZCJ 06G · Polestar 2")

        // Test fallback when registration is empty
        let regFallback = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: nil,
            format: .registration
        )
        XCTAssertEqual(regFallback, "Silver Comet")
    }

    @Test
    func testFeatureSelectionCanDisableOptionalCapabilities() {
        var features = FeatureSelection.default
        XCTAssertTrue(features.contains(.vehicleImage))
        XCTAssertTrue(features.contains(.chargingDetails))
        XCTAssertFalse(features.contains(.connectivityDiagnostics))
        XCTAssertFalse(features.contains(.airQuality))
        // batteryDiagnostics ships on by default now, alongside vehicleWeather and
        // ownerGreeting — see FeatureSelection.default.
        XCTAssertTrue(features.contains(.batteryDiagnostics))
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
    func testMergedLastKnownCategoriesAreExplicitlyLabelled() {
        var previous = vehicle(vin: "VIN-A", battery: 64)
        previous.exteriorStatus = ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: false)
        let current = vehicle(vin: "VIN-A", battery: 65)
        let merged = current.mergingLastKnown(from: previous, features: .default)
        XCTAssertEqual(merged.exteriorStatus?.isLocked, true)
        XCTAssertTrue(merged.retainedDataCategories.contains(.exteriorStatus))
        XCTAssertNotNil(merged.retainedDataAt)
    }

    @Test
    func testDiskSnapshotExpiresAndOmitsPersonalDetails() throws {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
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
        let stable = #"[{"tag_name":"v3.0.0","draft":false,"prerelease":false}]"#.data(using: .utf8)!
        let prerelease = #"[{"tag_name":"v4.0.0-beta.1","draft":false,"prerelease":true}]"#.data(using: .utf8)!
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: stable, currentVersion: "2.4.1"),
                           .updateAvailable("3.0.0"))
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: stable, currentVersion: "3.0.0"), .upToDate)
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: prerelease, currentVersion: "2.4.1"), .upToDate)
    }

    @Test
    func testReleaseEvaluationSkipsRollingLatestTagAndPicksHighestSemver() throws {
        // The CI pipeline republishes a non-semver "latest" rolling build on every push to
        // main, so it's almost always the most recently published release. The evaluator
        // must ignore it and pick the highest real version tag instead.
        let releases = #"""
        [
          {"tag_name":"latest","draft":false,"prerelease":false},
          {"tag_name":"v1.0.0","draft":false,"prerelease":false},
          {"tag_name":"v2.1.0","draft":false,"prerelease":false},
          {"tag_name":"v2.5.0","draft":true,"prerelease":false}
        ]
        """#.data(using: .utf8)!
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: releases, currentVersion: "1.5.0"),
                           .updateAvailable("2.1.0"))
        try XCTAssertEqual(UpdateChecker.evaluateRelease(data: releases, currentVersion: "2.1.0"), .upToDate)
    }

    @Test
    func testGreetingUsesSelectedInterfaceLanguage() {
        // Resolve through the explicit-language API rather than assigning
        // Preferences.interfaceLanguage. That preference is process-global, and the suite
        // runs in parallel, so mutating it here made unrelated tests read Swedish strings
        // for the duration — see the macos-14 failures in VolvoDecodingTests and
        // VehicleServiceErrorTests, which passed on macos-15 purely by scheduling luck.
        XCTAssertEqual(InterfaceLanguage.english.languageCode, "en")
        XCTAssertEqual(InterfaceLanguage.swedish.languageCode, "sv")
        XCTAssertEqual(Format.greeting("Nicolas", languageCode: InterfaceLanguage.english.languageCode), "Hi, Nicolas")
        XCTAssertEqual(Format.greeting("Nicolas", languageCode: InterfaceLanguage.swedish.languageCode), "Hej, Nicolas")
    }

    @Test
    func testSwedishVehicleCardsDoNotFallBackToEnglishKeys() {
        // Explicit language, for the same reason as above: no process-global mutation.
        func sv(_ key: String) -> String { L10n.text(key, languageCode: "sv") }

        XCTAssertEqual(sv("Charging & Energy"), "Laddning och energi")
        XCTAssertEqual(sv("Charger Connection"), "Laddkontakt")
        XCTAssertEqual(sv("Est. Charge Cost"), "Beräknad laddkostnad")
        XCTAssertEqual(sv("Power Module"), "Laddarmodul")
        XCTAssertEqual(sv("Vehicle Status"), "Fordonsstatus")
        XCTAssertEqual(sv("Odometer"), "Mätarställning")
        XCTAssertEqual(sv("Cloud Connectivity"), "Molnanslutning")
        XCTAssertEqual(sv("Climate & Timers"), "Klimat och timers")
        XCTAssertEqual(sv("Cabin Climate"), "Kupéklimat")
        XCTAssertEqual(sv("Complete"), "Fulladdad")
        XCTAssertEqual(sv("Securely Locked"), "Låst")
        XCTAssertEqual(sv("Current Limit"), "Maximal laddström")
        XCTAssertEqual(sv("Window controls"), "Rutreglage")
        XCTAssertEqual(sv("Range Health Estimate"), "Räckviddsbedömning")
        XCTAssertEqual(sv("System Default"), "Följ systemet")
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
        // Charging-aware renders as "82%→90 · 1h42m": the arrow shows time-to-TARGET when a
        // sub-100 % target is set, answering "when do I unplug" rather than "when is it full".
        XCTAssertEqual(Format.barTitle(for: chargingCar, style: .chargingAware, unit: .kilometers), "82%→90 · 1h42m")
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
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
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
    func testMenuBarTintingPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(store.tintMenuBarIcon)
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
    func testVehicleNicknamesAreStoredPerVIN() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstVIN = "YSMNICKNAME000001"
        let secondVIN = "YSMNICKNAME000002"

        store.setVehicleNickname("Comet", for: firstVIN)
        store.setVehicleNickname("Nova", for: secondVIN)

        XCTAssertEqual(store.vehicleNickname(for: firstVIN), "Comet")
        XCTAssertEqual(store.vehicleNickname(for: secondVIN), "Nova")
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

    @Test
    func testShortDateFormattingHasNoTime() {
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = 2030
        comps.month = 12
        comps.day = 26
        comps.hour = 14
        comps.minute = 30
        comps.second = 0
        let date = calendar.date(from: comps) ?? Date()
        let formatted = Format.shortDate(date: date)
        XCTAssertFalse(formatted.isEmpty)
        XCTAssertFalse(formatted.contains(":"))
    }
}

func vehicle(
    vin: String = "YSMTEST",
    battery: Double? = 50,
    state: ChargingState = .idle,
    connection: ChargerConnection = .disconnected,
    target: Int? = 80,
    fetchedAt: Date = Date(),
    reportedAt: Date? = Date(),
    brand: VehicleBrand? = nil
) -> VehicleState {
    // `VehicleState.model` derives its family from the model name, so an explicit brand
    // request maps to a representative model name rather than forcing a field that does
    // not exist on the state.
    let modelName: String
    switch brand {
    case .volvo: modelName = "XC40"
    case .polestar, nil: modelName = "Polestar 2"
    }
    return VehicleState(
        batteryPercentage: battery, rangeKm: 200, chargingState: state,
        estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: target,
        chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
        chargingType: .unknown, chargerConnection: connection, availability: .available,
         modelName: modelName, modelYear: "2023", registrationNo: nil, vin: vin,
        ownerFirstName: nil, odometerKm: nil, daysToService: nil,
        distanceToServiceKm: nil, serviceWarning: false, fluidWarnings: [], imageData: nil,
        fetchedAt: fetchedAt, vehicleReportedAt: reportedAt, dataWarnings: []
    )
}
