import Foundation
import Testing
@testable import Hisingen

struct MeasurementUnitsAndThemeTests {

    @Test
    @MainActor
    func testInjectedPreferencesStoreOwnsPanelAndPrivacySettings() throws {
        let suiteName = "HisingenTests.preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        #expect(!(store.floatingChargingPanelEnabled))
        #expect(!(store.privacyRedactionEnabled))
        store.floatingChargingPanelEnabled = true
        store.privacyRedactionEnabled = true
        #expect(defaults.bool(forKey: "floating_charging_panel"))
        #expect(defaults.bool(forKey: "privacy_redaction_enabled"))
    }

    @Test
    func testFuelVolumeUnitConversions() {
        let liters = 50.0

        let litersConverted = FuelVolumeUnit.liters.convert(liters: liters)
        #expect(litersConverted == 50.0)
        #expect(FuelVolumeUnit.liters.suffix == "L")

        let usGallons = FuelVolumeUnit.gallonsUS.convert(liters: liters)
        #expect(round(usGallons * 10) / 10 == 13.2)
        #expect(FuelVolumeUnit.gallonsUS.suffix == "gal")

        let ukGallons = FuelVolumeUnit.gallonsUK.convert(liters: liters)
        #expect(round(ukGallons * 10) / 10 == 11.0)
        #expect(FuelVolumeUnit.gallonsUK.suffix == "UK gal")

        #expect(Format.fuelVolume(liters: 45.0, unit: .liters) == "45.0 L")
        #expect(Format.fuelVolume(liters: 45.0, unit: .gallonsUS) == "11.9 gal")
    }

    @Test
    func testFuelEconomyUnitFormatting() {
        let lPer100Km = 6.5

        #expect(FuelEconomyUnit.litersPer100Km.format(lPer100Km: lPer100Km) == "6.5 L/100km")
        #expect(FuelEconomyUnit.milesPerGallonUS.format(lPer100Km: lPer100Km) == "36.2 mpg")
        #expect(FuelEconomyUnit.milesPerGallonUK.format(lPer100Km: lPer100Km) == "43.5 mpg (UK)")
        #expect(FuelEconomyUnit.kmPerLiter.format(lPer100Km: lPer100Km) == "15.4 km/L")

        #expect(Format.fuelEconomy(lPer100Km: 6.5, unit: .litersPer100Km) == "6.5 L/100km")
        #expect(Format.fuelEconomy(lPer100Km: 6.5, unit: .milesPerGallonUS) == "36.2 mpg")
    }

    @Test
    func testUSUnitFormatting() {
        #expect(Format.temperature(celsius: 20, unit: .fahrenheit) == "68.0 °F")
        #expect(Format.pressure(kilopascals: 241.3, unit: .psi) == "35.0 psi")
        #expect(Format.distance(km: 13.1, unit: .miles) == "8.1 mi")
    }

    @Test
    func testElectricConsumptionFormatting() {
        #expect(Format.energyConsumption(kwhPer100Km: 20, unit: .kwhPer100Km) == "20.0 kWh/100 km")
        #expect(Format.energyConsumption(kwhPer100Km: 20, unit: .kwhPer100Miles) == "32.2 kWh/100 mi")
        #expect(Format.energyConsumption(kwhPer100Km: 20, unit: .milesPerKwh) == "3.11 mi/kWh")
    }

    @Test
    func testExteriorDoorCountExcludesOtherOpenings() {
        let snapshot = ExteriorSnapshot(
            openings: [
                .init(opening: .frontLeftDoor, state: .closed),
                .init(opening: .frontRightDoor, state: .closed),
                .init(opening: .rearLeftDoor, state: .closed),
                .init(opening: .rearRightDoor, state: .closed),
                .init(opening: .frontLeftWindow, state: .closed),
                .init(opening: .frontRightWindow, state: .closed),
                .init(opening: .rearLeftWindow, state: .closed),
                .init(opening: .rearRightWindow, state: .closed),
                .init(opening: .hood, state: .closed),
                .init(opening: .tailgate, state: .closed),
                .init(opening: .chargeLid, state: .closed)
            ],
            isLocked: true,
            alarmTriggered: false
        )
        #expect(snapshot.openings.count == 11)
        #expect(snapshot.physicalDoorCount == 4)
    }

    @Test
    func testOnlyRecentDistinctSoftwareFailuresRequireAttention() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = VehicleSoftwareInfo(
            version: "5.1", state: .failed, updatedAt: now.addingTimeInterval(-86_400),
            installedVersion: "5.0", latestAvailableVersion: "5.1"
        )
        let old = VehicleSoftwareInfo(
            version: "5.1", state: .failed, updatedAt: now.addingTimeInterval(-31 * 86_400),
            installedVersion: "5.0", latestAvailableVersion: "5.1"
        )
        let alreadyInstalled = VehicleSoftwareInfo(
            version: "5.1", state: .failed, updatedAt: now,
            installedVersion: "5.1", latestAvailableVersion: "5.1"
        )
        #expect(recent.hasActionableFailure(at: now))
        #expect(!(old.hasActionableFailure(at: now)))
        #expect(!(alreadyInstalled.hasActionableFailure(at: now)))
    }

    @Test
    @MainActor
    func testSoftwareEventDismissalIsPerVehicleAndReversible() throws {
        let suiteName = "hisingen.tests.software-dismissal.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        store.setDismissedSoftwareEventIdentifier("event-a", for: "YSMTESTA")
        #expect(store.dismissedSoftwareEventIdentifier(for: "ysmtesta") == "event-a")
        #expect(store.dismissedSoftwareEventIdentifier(for: "YSMTESTB") == nil)

        store.setDismissedSoftwareEventIdentifier(nil, for: "YSMTESTA")
        #expect(store.dismissedSoftwareEventIdentifier(for: "YSMTESTA") == nil)
    }

    @Test
    func testThemeSystemCatalog() {
        #expect(AppTheme.allCases.count == 9)

        for theme in AppTheme.allCases {
            #expect(!(theme.title.isEmpty))
            #expect(!(theme.subtitle.isEmpty))
            #expect(!(theme.accentColorHex.isEmpty))
            #expect(theme.previewHexColors.count >= 3)
        }

        #expect(AppTheme.hisingen.category == .brand)
        #expect(AppTheme.polestar.category == .brand)
        #expect(AppTheme.volvo.category == .brand)
        #expect(AppTheme.polestar.rawValue == "polestar")
        #expect(AppTheme.volvo.rawValue == "volvo")
        #expect(!(AppTheme.polestar.title.localizedCaseInsensitiveContains("Polestar")))
        #expect(!(AppTheme.volvo.title.localizedCaseInsensitiveContains("Volvo")))
        #expect(AppTheme.nordicNight.category == .dark)
        #expect(AppTheme.aurora.category == .nature)
        #expect(AppTheme.swedishGold.category == .sport)
        #expect(AppTheme.cyanRacing.category == .sport)
        #expect(AppTheme.forest.category == .nature)
        #expect(AppTheme.sandDune.category == .brand)
    }

    @Test
    @MainActor
    func testAppearanceModeOptions() throws {
        #expect(AppearanceMode.allCases.count == 3)
        #expect(AppearanceMode.system.title == L10n.text("System (Automatic)"))
        #expect(AppearanceMode.light.title == L10n.text("Light"))
        #expect(AppearanceMode.dark.title == L10n.text("Dark"))

        #expect(AppearanceMode.system.colorScheme == nil)
        #expect(AppearanceMode.light.colorScheme == .light)
        #expect(AppearanceMode.dark.colorScheme == .dark)

        #expect(AppearanceMode.system.nsAppearance == nil)
        #expect(AppearanceMode.light.nsAppearance?.name == .aqua)
        #expect(AppearanceMode.dark.nsAppearance?.name == .darkAqua)

        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        store.appearanceMode = .light
        #expect(store.appearanceMode == .light)

        store.appearanceMode = .dark
        #expect(store.appearanceMode == .dark)

        store.appearanceMode = .system
        #expect(store.appearanceMode == .system)
    }

    @Test
    func testOutlineGeometryCalculations() {
        let og = OutlineGeometry(containerWidth: 380, containerHeight: 96)
        let expectedWidth = 96.0 * (1645.0 / 769.0)
        // Mixed CGFloat/Double equality inside #expect miscompares (the old shim silently
        // unified the types), so convert explicitly and compare same-type.
        #expect(round(og.imageWidth * 10) / 10 == round(CGFloat(expectedWidth) * 10) / 10)
        #expect(og.imageHeight == 96.0)

        let rearWheel = og.point(u: 0.2304, v: 0.6710)
        let frontWheel = og.point(u: 0.8036, v: 0.6710)

        #expect(rearWheel.x < frontWheel.x)
        #expect(round(rearWheel.y) == round(frontWheel.y))
        #expect(rearWheel.x > og.originX)
        #expect(frontWheel.x < og.originX + og.imageWidth)

        // Validate SVG-mapped opening points
        let frontDoor = og.point(u: 0.5830, v: 0.5234)
        let rearDoor = og.point(u: 0.3632, v: 0.4584)
        let hood = og.point(u: 0.8095, v: 0.4388)
        let tailgate = og.point(u: 0.1350, v: 0.3900)
        let chargeLid = og.point(u: 0.2040, v: 0.3979)

        #expect(tailgate.x < rearDoor.x)
        #expect(rearDoor.x < frontDoor.x)
        #expect(frontDoor.x < hood.x)
        #expect(chargeLid.x < rearDoor.x)
    }

    // TESTS-14: testPolestarAndVolvoSoftwareVersionResolution was deleted — it only
    // asserted memberwise-init passthrough (each field equal to the literal it was built
    // with). Real software-version resolution/precedence is covered by
    // PolestarMyCarsTests.installedAndPendingVersionsRemainDistinct.

    @Test
    func testMenuBarStyleOptionsAndFormatting() {
        #expect(MenuBarStyle.allCases.count == 8)
        let sample = VehicleState(
            batteryPercentage: 85, rangeKm: 350, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 90,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
            modelName: "Polestar 2", modelYear: "2024", registrationNo: nil, vin: "YSMTEST",
            ownerFirstName: nil, odometerKm: 10000, daysToService: nil, distanceToServiceKm: nil,
            serviceWarning: false, fluidWarnings: [], exteriorStatus: ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: false),
            imageData: nil, fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: []
        )

        #expect(Format.barTitle(for: sample, style: .battery, unit: .kilometers) == "85%")
        #expect(Format.barTitle(for: sample, style: .range, unit: .kilometers) == "350km")
        #expect(Format.barTitle(for: sample, style: .iconOnly, unit: .kilometers) == "")
        #expect(Format.barTitle(for: sample, style: .lockAndBattery, unit: .kilometers) == "85%")
        #expect(Format.lockStatusSymbol(for: sample) == "lock.fill")
        #expect(sample.currentRangeVsModelWltpPercent() == 85.8)

        let volvoXC40 = VehicleState(
            batteryPercentage: 85, rangeKm: 350, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 90,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
            modelName: "XC40", modelYear: "2024", registrationNo: nil, vin: "YV1TEST",
            ownerFirstName: nil, odometerKm: 10000, daysToService: nil, distanceToServiceKm: nil,
            serviceWarning: false, fluidWarnings: [], exteriorStatus: ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: false),
            imageData: nil, fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: []
        )
        // 350km reported at 85% SOC vs the XC40's own 570km WLTP reference (Volvo models now
        // resolve via `hasModelReferenceSpecs`, not just Polestar).
        #expect(volvoXC40.currentRangeVsModelWltpPercent() == 72.2)

        // A VIN-specific override entered in Settings takes priority over the model table.
        let override = VehicleSpecificationOverride(usableBatteryCapacityKwh: nil, wltpRangeKm: 400)
        #expect(sample.currentRangeVsModelWltpPercent(specification: override) == 102.9)

        // Below the 20% low-SOC cutoff the vehicle's own range readout is considered too noisy.
        var lowBattery = sample
        lowBattery.energy.batteryPercentage = 15
        #expect(lowBattery.currentRangeVsModelWltpPercent() == nil)

        var unlockedSample = sample
        unlockedSample.exteriorStatus = ExteriorSnapshot(openings: [], isLocked: false, alarmTriggered: false)
        #expect(Format.lockStatusSymbol(for: unlockedSample) == "lock.open.fill")
    }

    @Test
    func testChargingSessionTariffCalculation() {
        let session = ChargingSession(
            id: UUID(), vin: "YSMTEST",
            startDate: Date().addingTimeInterval(-3600), endDate: Date(),
            startBatteryPercentage: 20, endBatteryPercentage: 80,
            kwhDelivered: 45.0, peakPowerWatts: 150000, cost: nil
        )

        #expect(session.cost == nil)
        #expect(session.estimatedCost(tariff: 0.20) == 9.0)
        #expect(session.estimatedCost(tariff: 1.50) == 67.5)
        #expect(session.estimatedCost(tariff: nil) == nil)
    }

    @Test
    func testRefreshPolicyAdaptiveInterval() {
        #expect(RefreshPolicy.regularInterval(isCharging: false, isClimateActive: false) == 600)
        #expect(RefreshPolicy.regularInterval(isCharging: true, isClimateActive: false) == 120)
        #expect(RefreshPolicy.regularInterval(isCharging: false, isClimateActive: true) == 120)
        #expect(RefreshPolicy.regularInterval(isCharging: true, isClimateActive: true) == 120)
    }
}

// rebuild-note: force recompile
