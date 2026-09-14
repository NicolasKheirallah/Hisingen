import Foundation
import Testing
@testable import Hisingen

@MainActor
struct FormattingTests {
    /// Isolated preference store per test — the dead `Preferences` global (deleted) wrote to
    /// `UserDefaults.standard` and leaked state across runs on developer machines.
    private func makeStore() throws -> (store: PreferencesStore, defaults: UserDefaults, suiteName: String) {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (PreferencesStore(defaults: defaults), defaults, suiteName)
    }

    /// Locale-aware kW string mirroring `Format.powerKw`'s decimals rule, so expectations
    /// hold on comma-decimal systems too (the formatter is intentionally locale-aware).
    private func expectedKw(_ kw: Double) -> String {
        let decimals = kw >= 10 ? 0 : 1
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: kw))! + " kW"
    }

    @Test
    func testShortDuration() {
        #expect(Format.shortDuration(minutes: 45) == "45min")
        #expect(Format.shortDuration(minutes: 60) == "1h")
        #expect(Format.shortDuration(minutes: 135) == "2h15m")
    }

    @Test
    func testDistanceFormattingAndConversion() {
        #expect(DistanceUnit.kilometers.convert(km: 412) == 412)
        #expect(DistanceUnit.miles.convert(km: 412) == 256)
        #expect(Format.distance(km: 412, unit: .kilometers) == "412 km")
        #expect(Format.distance(km: 412, unit: .miles) == "256 mi")
        let grouped = Format.distance(km: 23_412, grouped: true, unit: .kilometers)
        #expect(grouped.hasSuffix(" km"))
        #expect(grouped.contains("23"))
    }

    @Test
    func testLegacyPreferenceValuesMigrate() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Range (km)", forKey: "statusbar_display_option")
        defaults.set("Miles (mi)", forKey: "distance_unit")
        #expect(store.menuBarStyle == .range)
        #expect(store.distanceUnit == .miles)
    }

    @Test
    func testVehicleModelBadgePositionPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.vehicleModelBadgePosition == .inlineHeader)
        store.vehicleModelBadgePosition = .topRightOverlay
        #expect(store.vehicleModelBadgePosition == .topRightOverlay)
        store.vehicleModelBadgePosition = .topLeftOverlay
        #expect(store.vehicleModelBadgePosition == .topLeftOverlay)
        store.vehicleModelBadgePosition = .subheadline
        #expect(store.vehicleModelBadgePosition == .subheadline)
        store.vehicleModelBadgePosition = .hidden
        #expect(store.vehicleModelBadgePosition == .hidden)
        store.vehicleModelBadgePosition = .inlineHeader
        #expect(store.vehicleModelBadgePosition == .inlineHeader)
    }

    @Test
    func testRegistrationBadgePositionPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.registrationBadgePosition == .belowGreeting)
        store.registrationBadgePosition = .platePill
        #expect(store.registrationBadgePosition == .platePill)
        store.registrationBadgePosition = .inlineHeader
        #expect(store.registrationBadgePosition == .inlineHeader)
        store.registrationBadgePosition = .topRightOverlay
        #expect(store.registrationBadgePosition == .topRightOverlay)
        store.registrationBadgePosition = .topLeftOverlay
        #expect(store.registrationBadgePosition == .topLeftOverlay)
        store.registrationBadgePosition = .hidden
        #expect(store.registrationBadgePosition == .hidden)
        store.registrationBadgePosition = .belowGreeting
        #expect(store.registrationBadgePosition == .belowGreeting)
    }

    @Test
    func testVehicleLabelFormatPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.vehicleLabelFormat == .modelAndYear)
        store.vehicleLabelFormat = .registration
        #expect(store.vehicleLabelFormat == .registration)
        store.vehicleLabelFormat = .nickname
        #expect(store.vehicleLabelFormat == .nickname)
        store.vehicleLabelFormat = .modelOnly
        #expect(store.vehicleLabelFormat == .modelOnly)
        store.vehicleLabelFormat = .nicknameAndRegistration
        #expect(store.vehicleLabelFormat == .nicknameAndRegistration)
        store.vehicleLabelFormat = .registrationAndModel
        #expect(store.vehicleLabelFormat == .registrationAndModel)
        store.vehicleLabelFormat = .modelAndYear
        #expect(store.vehicleLabelFormat == .modelAndYear)
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
        #expect(regTitle == "ZCJ 06G")

        // Test Nickname Format
        let nickTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .nickname
        )
        #expect(nickTitle == "Silver Comet")

        // Test Model & Year Format
        let modelYrTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .modelAndYear
        )
        #expect(modelYrTitle == "Polestar 2 · 2024")

        // Test Model Only Format
        let modelOnlyTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .modelOnly
        )
        #expect(modelOnlyTitle == "Polestar 2")

        // Test Nickname & Registration Format
        let nickAndRegTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .nicknameAndRegistration
        )
        #expect(nickAndRegTitle == "Silver Comet (ZCJ 06G)")

        // Test Registration & Model Format
        let regAndModelTitle = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "ZCJ 06G",
            format: .registrationAndModel
        )
        #expect(regAndModelTitle == "ZCJ 06G · Polestar 2")

        // Test fallback when registration is empty
        let regFallback = store.formattedVehicleTitle(
            vin: testVIN,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: nil,
            format: .registration
        )
        #expect(regFallback == "Silver Comet")
    }

    @Test
    func testFeatureSelectionCanDisableOptionalCapabilities() {
        var features = FeatureSelection.default
        #expect(features.contains(.vehicleImage))
        #expect(features.contains(.chargingDetails))
        #expect(!(features.contains(.connectivityDiagnostics)))
        #expect(!(features.contains(.airQuality)))
        // batteryDiagnostics ships on by default now, alongside vehicleWeather and
        // ownerGreeting — see FeatureSelection.default.
        #expect(features.contains(.batteryDiagnostics))
        #expect(!(features.contains(.vehicleHealth)))
        #expect(!(AppFeature.remoteFeatures.contains { features.contains($0) }))
        features.set(.chargingDetails, enabled: false)
        features.set(.vehicleImage, enabled: false)
        #expect(!(features.contains(.chargingDetails)))
        #expect(!(features.contains(.vehicleImage)))
    }

    @Test
    func testRemoteFeaturesAreOptInAndSelectable() {
        let selection = FeatureSelection.default
        #expect(!(AppFeature.remoteFeatures.contains { selection.contains($0) }))
        #expect(AppFeature.userSelectableCases.contains(.remoteClimate))
    }

    @Test
    func testVINValidationSupportsGuestAccountFallback() {
        #expect(PolestarAPI.isValidVIN("YSMVSEDE6PL000001"))
        #expect(!(PolestarAPI.isValidVIN("TOO-SHORT")))
        #expect(!(PolestarAPI.isValidVIN("YSMVSEDEIPL147228")))
    }

    @Test
    func testHealthFeatureControlsGraphQLSelections() {
        var features = FeatureSelection.default
        features.set(.vehicleHealth, enabled: true)
        let enabled = PolestarAPI.telematicsQuery(features: features)
        #expect(enabled.contains("odometerMeters"))
        #expect(enabled.contains("daysToService"))
        features.set(.vehicleHealth, enabled: false)
        let disabled = PolestarAPI.telematicsQuery(features: features)
        #expect(!(disabled.contains("odometerMeters")))
        #expect(!(disabled.contains("daysToService")))
        #expect(disabled.contains("batteryChargeLevelPercentage"))
    }

    @Test
    func testTelematicsQueryOmitsRemovedBatteryCapacityField() {
        let query = PolestarAPI.telematicsQuery(features: .default)
        #expect(!(query.contains("reportedBatteryCapacityKwh")))
    }

    @Test
    func testMissingCoreTelemetryKeepsLastKnownValueForSameVIN() {
        let previous = vehicle(vin: "VIN-A", battery: 64)
        let current = vehicle(vin: "VIN-A", battery: nil)
        let merged = current.mergingLastKnown(from: previous, features: .default)
        #expect(merged.energy.batteryPercentage == 64)
        #expect(current.mergingLastKnown(
            from: vehicle(vin: "VIN-B", battery: 81), features: .default
        ).energy.batteryPercentage == nil)
    }

    @Test
    func testMergedLastKnownCategoriesAreExplicitlyLabelled() {
        var previous = vehicle(vin: "VIN-A", battery: 64)
        previous.exteriorStatus = ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: false)
        let current = vehicle(vin: "VIN-A", battery: 65)
        let merged = current.mergingLastKnown(from: previous, features: .default)
        #expect(merged.exteriorStatus?.isLocked == true)
        #expect(merged.freshness.retainedDataCategories.contains(.exteriorStatus))
        #expect(merged.freshness.retainedDataAt != nil)
    }

    @Test
    func testUnsupportedConnectivityDoesNotRetainAnObsoleteReading() {
        var previous = vehicle(vin: "VIN-A")
        previous.connectivity = VehicleConnectivity(state: .connected, networkType: "LTE")
        var current = vehicle(vin: "VIN-A")
        var probes = VehicleProbedCapabilities()
        probes.record(.connectivity, as: .unavailable)
        current.probedCapabilities = probes

        var features = FeatureSelection.default
        features.set(.connectivityDiagnostics, enabled: true)
        let merged = current.mergingLastKnown(from: previous, features: features)

        #expect(merged.connectivity == nil)
        #expect(!(merged.freshness.retainedDataCategories.contains(.connectivityDiagnostics)))
    }

    @Test
    func testRetainedDataNoticeIdentityChangesOnlyForANewIncident() throws {
        let sourceAt = Date(timeIntervalSince1970: 1_700_000_000)
        var first = vehicle(vin: "VIN-A")
        first.freshness.retainedDataCategories = [.exteriorStatus, .vehicleLocation]
        first.freshness.retainedDataAt = sourceAt
        var sameIncident = first
        sameIncident.freshness.fetchedAt = sourceAt.addingTimeInterval(300)
        var differentCategory = sameIncident
        differentCategory.freshness.retainedDataCategories = [.exteriorStatus]
        var newerIncident = first
        newerIncident.freshness.retainedDataAt = sourceAt.addingTimeInterval(600)

        let firstID = try #require(RetainedDataNoticeID(state: first))
        #expect(firstID == RetainedDataNoticeID(state: sameIncident))
        #expect(firstID != RetainedDataNoticeID(state: differentCategory))
        #expect(firstID != RetainedDataNoticeID(state: newerIncident))

        var fresh = first
        fresh.freshness.retainedDataCategories = []
        #expect(RetainedDataNoticeID(state: fresh) == nil)
    }

    @Test
    func testDiskSnapshotExpiresAndOmitsPersonalDetails() throws {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
        let stale = vehicle(
            vin: "VIN-A", fetchedAt: Date().addingTimeInterval(-8 * 24 * 60 * 60), reportedAt: nil
        )
        store.save(stale)
        #expect(store.snapshot(for: "VIN-A") == nil)
        #expect(stale.cacheableCopy.identity.ownerFirstName == nil)
        #expect(stale.cacheableCopy.identity.registrationNo == nil)
        #expect(stale.cacheableCopy.identity.imageData == nil)
    }

    @Test
    func testKilowattsFormatting() {
        #expect(Format.kilowatts(watts: 7_200) == expectedKw(7.2))
        #expect(Format.kilowatts(watts: 11_000) == expectedKw(11))
        #expect(Format.kilowatts(watts: 150_000) == expectedKw(150))
    }

    @Test
    func testProtobufVarintRoundTripAndFrame() {
        for value: UInt64 in [0, 1, 127, 128, 300, 7_200, UInt64(Int32.max)] {
            var message = Protobuf.varint(UInt64(5 << 3))
            message.append(Protobuf.varint(value))
            let field = Protobuf.fields(message).first
            #expect(field?.number == 5)
            #expect(field?.varint == value)
        }
        let message = Protobuf.stringField(2, "LPSVSESEKML123456")
        let frame = Protobuf.grpcFrame(message)
        #expect(frame[0] == 0)
        #expect(frame.count == message.count + 5)
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
        #expect(result.batteryPercentage == 54.5)
        #expect(result.rangeKm == 321)
        #expect(result.estimatedChargingTimeToFullMinutes == 95)
        #expect(result.chargerConnection == .connected)
        #expect(result.chargingState == .charging)
        #expect(result.chargingType == .ac)
        #expect(result.chargingPowerWatts == 7_200)
        #expect(result.chargingCurrentAmps == 16)
        #expect(result.chargingVoltageVolts == 230)
    }

    @Test
    func testTypedChargingStateAndIcons() {
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_SMART_CHARGING") == .smartCharging)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_CHARGING").isActivelyCharging)
        #expect(!(ChargingState(apiValue: "CHARGING_STATUS_IDLE").isActivelyCharging))
        #expect(Format.icon(for: vehicle(state: .charging, connection: .connected)) == "bolt.car.fill")
        #expect(Format.icon(for: vehicle(state: .idle, connection: .connected)) == "bolt.car")
        #expect(Format.icon(for: vehicle(state: .idle, connection: .disconnected)) == "car")
        #expect(Format.icon(
            for: vehicle(state: .charging, connection: .connected), includeConnection: false
        ) == "car")
        #expect(Format.icon(for: nil) == "car")
    }

    @Test
    func testStaleThresholdIsStricterWhileCharging() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(vehicle(state: .charging, fetchedAt: now.addingTimeInterval(-901),
                              reportedAt: now.addingTimeInterval(-901)).isStale(at: now))
        #expect(!(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-901),
                               reportedAt: now.addingTimeInterval(-901)).isStale(at: now)))
        #expect(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-3_601),
                              reportedAt: now.addingTimeInterval(-3_601)).isStale(at: now))
    }

    @Test
    func testFreshFetchIsNotStaleEvenWhenVehicleReportsOldData() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)


        #expect(!(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-30),
                               reportedAt: now.addingTimeInterval(-10_800)).isStale(at: now)))

        #expect(vehicle(state: .idle, fetchedAt: now.addingTimeInterval(-130),
                              reportedAt: now.addingTimeInterval(-10_800)).isStale(at: now))
    }

    @Test
    func testGreetingUsesSelectedInterfaceLanguage() {
        // Resolve through the explicit-language API rather than assigning
        // Preferences.interfaceLanguage. That preference is process-global, and the suite
        // runs in parallel, so mutating it here made unrelated tests read Swedish strings
        // for the duration — see the macos-14 failures in VolvoDecodingTests and
        // VehicleServiceErrorTests, which passed on macos-15 purely by scheduling luck.
        #expect(InterfaceLanguage.english.languageCode == "en")
        #expect(InterfaceLanguage.swedish.languageCode == "sv")
        #expect(Format.greeting("Nicolas", languageCode: InterfaceLanguage.english.languageCode) == "Hi, Nicolas")
        #expect(Format.greeting("Nicolas", languageCode: InterfaceLanguage.swedish.languageCode) == "Hej, Nicolas")
    }

    @Test
    func testSwedishVehicleCardsDoNotFallBackToEnglishKeys() {
        // Explicit language, for the same reason as above: no process-global mutation.
        func sv(_ key: String) -> String { L10n.text(key, languageCode: "sv") }

        #expect(sv("Charging & Energy") == "Laddning och energi")
        #expect(sv("Charger Connection") == "Laddkontakt")
        #expect(sv("Est. Charge Cost") == "Beräknad laddkostnad")
        #expect(sv("Power Module") == "Laddarmodul")
        #expect(sv("Vehicle Status") == "Fordonsstatus")
        #expect(sv("Odometer") == "Mätarställning")
        #expect(sv("Cloud Connectivity") == "Molnanslutning")
        #expect(sv("Climate & Timers") == "Klimat och timers")
        #expect(sv("Cabin Climate") == "Kupéklimat")
        #expect(sv("Complete") == "Fulladdad")
        #expect(sv("Securely Locked") == "Låst")
        #expect(sv("Current Limit") == "Maximal laddström")
        #expect(sv("Window controls") == "Rutreglage")
        #expect(sv("Range Health Estimate") == "Räckviddsbedömning")
        #expect(sv("System Default") == "Följ systemet")
    }

    @Test
    func testChargingRateFormatting() {
        #expect(Format.chargingRateKmPerHour(powerWatts: 7_200, consumptionWhPerKm: 180) == 40)
        #expect(Format.chargingRateKmPerHour(powerWatts: 150_000, consumptionWhPerKm: 200) == 750)
        #expect(Format.chargingRateKmPerHour(powerWatts: 0) == 0)

        #expect(Format.chargingRateFormatted(powerWatts: 7_200, unit: .kilometers) == "+40 km/h")
        #expect(Format.chargingRateFormatted(powerWatts: 7_200, unit: .miles) == "+25 mph")
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

        #expect(Format.barTitle(for: chargingCar, style: .battery, unit: .kilometers) == "82%")
        #expect(Format.barTitle(for: chargingCar, style: .batteryAndRange, unit: .kilometers) == "82% · 348km")
        // Charging-aware renders as "82%→90 · 1h42m": the arrow shows time-to-TARGET when a
        // sub-100 % target is set, answering "when do I unplug" rather than "when is it full".
        #expect(Format.barTitle(for: chargingCar, style: .chargingAware, unit: .kilometers) == "82%→90 · 1h42m")
        #expect(Format.barTitle(for: chargingCar, style: .compactCharging, unit: .kilometers) == "82% (1h42m)")
        #expect(Format.barTitle(for: chargingCar, style: .batteryAndPower, unit: .kilometers) == "82% · \(expectedKw(7.2))")
        #expect(Format.barTitle(for: chargingCar, style: .range, unit: .kilometers) == "348km")

        let idleCar = vehicle(battery: 82, state: .idle, connection: .disconnected)
        #expect(Format.barTitle(for: idleCar, style: .compactCharging, unit: .kilometers) == "82%")
        #expect(Format.barTitle(for: idleCar, style: .batteryAndPower, unit: .kilometers) == "82% · 200km")
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

        #expect(chargingCar.formattedCompletionTime != nil)
        #expect(chargingCar.formattedChargingRate(unit: .kilometers) == "+70 km/h")
        #expect(chargingCar.freshnessDescription.contains("Updated"))
    }

    @Test
    func testChargingSessionSamplesAndSparklineBuffering() {
        var state1 = vehicle(battery: 50, state: .charging, connection: .connected)
        let sample1 = ChargingSample(timestamp: Date(timeIntervalSince1970: 1000), batteryPercentage: 50, powerWatts: 7200)
        state1.energy.samples = [sample1]

        let state2 = vehicle(battery: 52, state: .charging, connection: .connected, fetchedAt: Date(timeIntervalSince1970: 1060))
        let merged = state2.mergingLastKnown(from: state1, features: .default)

        #expect(merged.energy.samples.count == 2)
        #expect(merged.energy.samples.first?.batteryPercentage == 50)
        #expect(merged.energy.samples.last?.batteryPercentage == 52)


        let idleState = vehicle(battery: 80, state: .idle, connection: .disconnected)
        let cleared = idleState.mergingLastKnown(from: merged, features: .default)
        #expect(cleared.energy.samples.isEmpty)
    }

    @Test
    func testChargingSessionSamplesSurviveCachedStateRoundTrip() async throws {
        let suiteName = "HisingenTests.ChargingSamples.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var state = vehicle(battery: 64, state: .charging, connection: .connected)
        state.energy.samples = [
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_000), batteryPercentage: 61, powerWatts: 6_200),
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_060), batteryPercentage: 64, powerWatts: 6_100)
        ]
        let store = VehicleStateStore(defaults: defaults, database: .inMemory())
        store.save(state)
        // Persistence hands off to a detached storage pass; wait for the snapshot to land.
        let stored = await awaitStored(timeout: 5) { store.snapshot(for: state.identity.vin) != nil }
        #expect(stored, "snapshot never reached the database after save")

        let restored = try #require(store.snapshot(for: state.identity.vin))
        #expect(restored.energy.samples == state.energy.samples)
    }

    @Test
    func testCompletedChargingSessionSummary() throws {
        var previous = vehicle(battery: 50, state: .charging, connection: .connected,
                               fetchedAt: Date(timeIntervalSince1970: 1_000))
        previous.energy.samples = [
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_000), batteryPercentage: 50, powerWatts: 7_200),
            ChargingSample(timestamp: Date(timeIntervalSince1970: 1_600), batteryPercentage: 60, powerWatts: 6_800)
        ]
        let current = vehicle(battery: 70, state: .idle, connection: .disconnected,
                              fetchedAt: Date(timeIntervalSince1970: 2_000))

        let session = try #require(ChargingSession.completed(previous: previous, current: current, pricePerKwh: 2))
        #expect(session.percentageAdded == 20)
        #expect(session.peakPowerWatts == 7_200)
        #expect(session.kwhDelivered > 0)
        #expect(session.cost == session.kwhDelivered * 2)
    }

    @Test
    func testMenuBarTintingPreference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.tintMenuBarIcon)
    }

    @Test
    @MainActor
    func testMultiCarIndexCyclingWrapsThroughStatusItemController() throws {
        // Drive the real cycling seam (TESTS-02): the arithmetic lives in
        // StatusItemController.cycleVehicle, which orders the fleet the way the menu bar
        // sees it, so a three-car fleet must step forward/backward and wrap at both ends.
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fleetStore = FleetStore(
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            preferences: store
        )
        let controller = StatusItemController(
            database: .inMemory(), preferences: store, fleetStore: fleetStore
        )
        let vins = ["YSMCYCLEAAA0000001", "YSMCYCLEBBB0000002", "YSMCYCLECCC0000003"]
        fleetStore.updateCars(vins.enumerated().map { index, vin in
            CarSummary(vin: vin, title: "Cycle car \(index + 1)")
        })
        var selected: [String] = []
        controller.onSelectCar = { selected.append($0) }

        func cycledVIN(forward: Bool) -> String? {
            controller.cycleVehicle(forward: forward)
            return selected.last
        }

        controller.activeVin = vins[0]
        #expect(cycledVIN(forward: true) == vins[1], "forward must advance to the next fleet car")
        #expect(cycledVIN(forward: true) == vins[2])
        #expect(cycledVIN(forward: true) == vins[0], "forward must wrap past the last car")
        #expect(cycledVIN(forward: false) == vins[2], "backward must wrap past the first car")
        #expect(cycledVIN(forward: false) == vins[1])
    }

    @Test
    func testVehicleNicknamesAreStoredPerVIN() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstVIN = "YSMNICKNAME000001"
        let secondVIN = "YSMNICKNAME000002"

        store.setVehicleNickname("Comet", for: firstVIN)
        store.setVehicleNickname("Nova", for: secondVIN)

        #expect(store.vehicleNickname(for: firstVIN) == "Comet")
        #expect(store.vehicleNickname(for: secondVIN) == "Nova")
    }

    @Test
    func testCompletionTimeFormatting() throws {
        // Fixed UTC fixture: the function must render baseDate + minutes in the timezone
        // it is given. The reference formatter mirrors the product configuration
        // (.short time, injected timezone) so the pin is locale-portable but still fails
        // on offset math, timezone, or style regressions.
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let utcZone = TimeZone(secondsFromGMT: 0)!
        let formattedUTC = Format.completionTime(from: 90, baseDate: baseDate, timeZone: utcZone)

        let reference = DateFormatter()
        reference.dateStyle = .none
        reference.timeStyle = .short
        reference.timeZone = utcZone
        let target = baseDate.addingTimeInterval(90 * 60)
        #expect(formattedUTC == reference.string(from: target), "completion time must render baseDate + 90 min in UTC")
        #expect(formattedUTC != reference.string(from: baseDate), "the +90 min offset must be visible in the rendered time")
    }

    @Test
    func testShortTimeFormatting() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 8
        comps.day = 15
        comps.hour = 18
        comps.minute = 52
        comps.second = 0
        let date = try #require(calendar.date(from: comps), "fixture construction must not silently fall back to now")

        // The product formatter is locale- and timezone-bound (Locale.current), so pin the
        // exact rendered instant via an identically-configured reference, plus a
        // cross-instant inequality that fails if the time component is dropped.
        let reference = DateFormatter()
        reference.dateStyle = .none
        reference.timeStyle = .short
        let formatted = Format.shortTime(date: date)
        #expect(formatted == reference.string(from: date))
        #expect(Format.shortTime(date: date.addingTimeInterval(10 * 3_600)) == reference.string(from: date.addingTimeInterval(10 * 3_600)), "a 10-hour offset must change the rendered time")
        #expect(!(formatted.isEmpty))
    }

    @Test
    func testShortDateFormattingHasNoTime() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        var comps = DateComponents()
        comps.year = 2030
        comps.month = 12
        comps.day = 26
        comps.hour = 14
        comps.minute = 30
        comps.second = 0
        let date = try #require(calendar.date(from: comps), "fixture construction must not silently fall back to now")

        let reference = DateFormatter()
        reference.dateStyle = .short
        reference.timeStyle = .none
        let formatted = Format.shortDate(date: date)
        #expect(formatted == reference.string(from: date), "short date must render the fixture's day, date-style short")
        #expect(Format.shortDate(date: date.addingTimeInterval(24 * 3_600)) == reference.string(from: date.addingTimeInterval(24 * 3_600)), "the next day must render differently")
        #expect(!(formatted.isEmpty))
        #expect(!(formatted.contains(":")), "a short date must not carry a time component")
    }
}
