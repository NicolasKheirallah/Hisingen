import Foundation
import AppKit
import Testing
@testable import Hisingen

struct MeasurementUnitsAndThemeTests {

    @Test
    func testFuelVolumeUnitConversions() {
        let liters = 50.0

        let litersConverted = FuelVolumeUnit.liters.convert(liters: liters)
        XCTAssertEqual(litersConverted, 50.0)
        XCTAssertEqual(FuelVolumeUnit.liters.suffix, "L")

        let usGallons = FuelVolumeUnit.gallonsUS.convert(liters: liters)
        XCTAssertEqual(round(usGallons * 10) / 10, 13.2)
        XCTAssertEqual(FuelVolumeUnit.gallonsUS.suffix, "gal")

        let ukGallons = FuelVolumeUnit.gallonsUK.convert(liters: liters)
        XCTAssertEqual(round(ukGallons * 10) / 10, 11.0)
        XCTAssertEqual(FuelVolumeUnit.gallonsUK.suffix, "UK gal")

        XCTAssertEqual(Format.fuelVolume(liters: 45.0, unit: .liters), "45.0 L")
        XCTAssertEqual(Format.fuelVolume(liters: 45.0, unit: .gallonsUS), "11.9 gal")
    }

    @Test
    func testFuelEconomyUnitFormatting() {
        let lPer100Km = 6.5

        XCTAssertEqual(FuelEconomyUnit.litersPer100Km.format(lPer100Km: lPer100Km), "6.5 L/100km")
        XCTAssertEqual(FuelEconomyUnit.milesPerGallonUS.format(lPer100Km: lPer100Km), "36.2 mpg")
        XCTAssertEqual(FuelEconomyUnit.milesPerGallonUK.format(lPer100Km: lPer100Km), "43.5 mpg (UK)")
        XCTAssertEqual(FuelEconomyUnit.kmPerLiter.format(lPer100Km: lPer100Km), "15.4 km/L")

        XCTAssertEqual(Format.fuelEconomy(lPer100Km: 6.5, unit: .litersPer100Km), "6.5 L/100km")
        XCTAssertEqual(Format.fuelEconomy(lPer100Km: 6.5, unit: .milesPerGallonUS), "36.2 mpg")
    }

    @Test
    func testUSUnitFormatting() {
        XCTAssertEqual(Format.temperature(celsius: 20, unit: .fahrenheit), "68.0 °F")
        XCTAssertEqual(Format.pressure(kilopascals: 241.3, unit: .psi), "35.0 psi")
        XCTAssertEqual(Format.distance(km: 13.1, unit: .miles), "8.1 mi")
    }

    @Test
    func testElectricConsumptionFormatting() {
        XCTAssertEqual(Format.energyConsumption(kwhPer100Km: 20, unit: .kwhPer100Km), "20.0 kWh/100 km")
        XCTAssertEqual(Format.energyConsumption(kwhPer100Km: 20, unit: .kwhPer100Miles), "32.2 kWh/100 mi")
        XCTAssertEqual(Format.energyConsumption(kwhPer100Km: 20, unit: .milesPerKwh), "3.11 mi/kWh")
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
        XCTAssertEqual(snapshot.openings.count, 11)
        XCTAssertEqual(snapshot.physicalDoorCount, 4)
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
        XCTAssertTrue(recent.hasActionableFailure(at: now))
        XCTAssertFalse(old.hasActionableFailure(at: now))
        XCTAssertFalse(alreadyInstalled.hasActionableFailure(at: now))
    }

    @Test
    @MainActor
    func testSoftwareEventDismissalIsPerVehicleAndReversible() throws {
        let suiteName = "hisingen.tests.software-dismissal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        store.setDismissedSoftwareEventIdentifier("event-a", for: "YSMTESTA")
        XCTAssertEqual(store.dismissedSoftwareEventIdentifier(for: "ysmtesta"), "event-a")
        XCTAssertNil(store.dismissedSoftwareEventIdentifier(for: "YSMTESTB"))

        store.setDismissedSoftwareEventIdentifier(nil, for: "YSMTESTA")
        XCTAssertNil(store.dismissedSoftwareEventIdentifier(for: "YSMTESTA"))
    }

    @Test
    func testThemeSystemCatalog() {
        XCTAssertEqual(AppTheme.allCases.count, 9)

        for theme in AppTheme.allCases {
            XCTAssertFalse(theme.title.isEmpty)
            XCTAssertFalse(theme.subtitle.isEmpty)
            XCTAssertFalse(theme.accentColorHex.isEmpty)
            XCTAssertTrue(theme.previewHexColors.count >= 3)
        }

        XCTAssertEqual(AppTheme.hisingen.category, .brand)
        XCTAssertEqual(AppTheme.polestar.category, .brand)
        XCTAssertEqual(AppTheme.volvo.category, .brand)
        XCTAssertEqual(AppTheme.nordicNight.category, .dark)
        XCTAssertEqual(AppTheme.aurora.category, .nature)
        XCTAssertEqual(AppTheme.swedishGold.category, .sport)
        XCTAssertEqual(AppTheme.cyanRacing.category, .sport)
        XCTAssertEqual(AppTheme.forest.category, .nature)
        XCTAssertEqual(AppTheme.sandDune.category, .brand)
    }

    @Test
    @MainActor
    func testAppearanceModeOptions() {
        XCTAssertEqual(AppearanceMode.allCases.count, 3)
        XCTAssertEqual(AppearanceMode.system.title, L10n.text("System (Automatic)"))
        XCTAssertEqual(AppearanceMode.light.title, L10n.text("Light"))
        XCTAssertEqual(AppearanceMode.dark.title, L10n.text("Dark"))

        XCTAssertNil(AppearanceMode.system.colorScheme)
        XCTAssertEqual(AppearanceMode.light.colorScheme, .light)
        XCTAssertEqual(AppearanceMode.dark.colorScheme, .dark)

        XCTAssertNil(AppearanceMode.system.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)

        Preferences.appearanceMode = .light
        XCTAssertEqual(Preferences.appearanceMode, .light)
        Preferences.applyAppearance()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)

        Preferences.appearanceMode = .dark
        XCTAssertEqual(Preferences.appearanceMode, .dark)
        Preferences.applyAppearance()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)

        Preferences.appearanceMode = .system
        XCTAssertEqual(Preferences.appearanceMode, .system)
        Preferences.applyAppearance()
        XCTAssertNil(NSApplication.shared.appearance as NSAppearance?)
    }

    @Test
    func testOutlineGeometryCalculations() {
        let og = OutlineGeometry(containerWidth: 380, containerHeight: 96)
        let expectedWidth = 96.0 * (1645.0 / 769.0)
        XCTAssertEqual(round(og.imageWidth * 10) / 10, round(expectedWidth * 10) / 10)
        XCTAssertEqual(og.imageHeight, 96.0)

        let rearWheel = og.point(u: 0.2304, v: 0.6710)
        let frontWheel = og.point(u: 0.8036, v: 0.6710)

        XCTAssertTrue(rearWheel.x < frontWheel.x)
        XCTAssertEqual(round(rearWheel.y), round(frontWheel.y))
        XCTAssertTrue(rearWheel.x > og.originX)
        XCTAssertTrue(frontWheel.x < og.originX + og.imageWidth)

        // Validate SVG-mapped opening points
        let frontDoor = og.point(u: 0.5830, v: 0.5234)
        let rearDoor = og.point(u: 0.3632, v: 0.4584)
        let hood = og.point(u: 0.8095, v: 0.4388)
        let tailgate = og.point(u: 0.1350, v: 0.3900)
        let chargeLid = og.point(u: 0.2040, v: 0.3979)

        XCTAssertTrue(tailgate.x < rearDoor.x)
        XCTAssertTrue(rearDoor.x < frontDoor.x)
        XCTAssertTrue(frontDoor.x < hood.x)
        XCTAssertTrue(chargeLid.x < rearDoor.x)
    }

    @Test
    func testPolestarAndVolvoSoftwareVersionResolution() {
        let volvoSoftware = VehicleSoftwareInfo(
            version: "5.1.17",
            title: "5.1.17",
            state: .completed,
            scheduledAt: nil,
            updatedAt: Date(),
            installedVersion: "5.1.17",
            latestAvailableVersion: "5.1.17"
        )
        XCTAssertEqual(volvoSoftware.installedVersion, "5.1.17")
        XCTAssertEqual(volvoSoftware.latestAvailableVersion, "5.1.17")
        XCTAssertEqual(volvoSoftware.version, "5.1.17")
        XCTAssertEqual(volvoSoftware.title, "5.1.17")
        XCTAssertEqual(volvoSoftware.state, .completed)

        let polestarSoftware = VehicleSoftwareInfo(
            version: "5.1.17",
            title: "5.1.17",
            state: .available,
            scheduledAt: Date(),
            updatedAt: Date(),
            installedVersion: "5.1.17",
            latestAvailableVersion: "5.1.17"
        )
        XCTAssertEqual(polestarSoftware.installedVersion, "5.1.17")
        XCTAssertEqual(polestarSoftware.latestAvailableVersion, "5.1.17")
        XCTAssertEqual(polestarSoftware.state, .available)
        XCTAssertNotNil(polestarSoftware.scheduledAt)
    }

    @Test
    func testMenuBarStyleOptionsAndFormatting() {
        XCTAssertEqual(MenuBarStyle.allCases.count, 8)
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

        XCTAssertEqual(Format.barTitle(for: sample, style: .battery, unit: .kilometers), "85%")
        XCTAssertEqual(Format.barTitle(for: sample, style: .range, unit: .kilometers), "350km")
        XCTAssertEqual(Format.barTitle(for: sample, style: .iconOnly, unit: .kilometers), "")
        XCTAssertEqual(Format.barTitle(for: sample, style: .lockAndBattery, unit: .kilometers), "85%")
        XCTAssertEqual(Format.lockStatusSymbol(for: sample), "lock.fill")
        XCTAssertEqual(sample.currentRangeVsModelWltpPercent(), 85.8)

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
        XCTAssertEqual(volvoXC40.currentRangeVsModelWltpPercent(), 72.2)

        // A VIN-specific override entered in Settings takes priority over the model table.
        let override = VehicleSpecificationOverride(usableBatteryCapacityKwh: nil, wltpRangeKm: 400)
        XCTAssertEqual(sample.currentRangeVsModelWltpPercent(specification: override), 102.9)

        // Below the 20% low-SOC cutoff the vehicle's own range readout is considered too noisy.
        var lowBattery = sample
        lowBattery.batteryPercentage = 15
        XCTAssertNil(lowBattery.currentRangeVsModelWltpPercent())

        var unlockedSample = sample
        unlockedSample.exteriorStatus = ExteriorSnapshot(openings: [], isLocked: false, alarmTriggered: false)
        XCTAssertEqual(Format.lockStatusSymbol(for: unlockedSample), "lock.open.fill")
    }

    @Test
    func testChargingSessionTariffCalculation() {
        let session = ChargingSession(
            id: UUID(), vin: "YSMTEST",
            startDate: Date().addingTimeInterval(-3600), endDate: Date(),
            startBatteryPercentage: 20, endBatteryPercentage: 80,
            kwhDelivered: 45.0, peakPowerWatts: 150000, cost: nil
        )

        XCTAssertNil(session.cost)
        XCTAssertEqual(session.estimatedCost(tariff: 0.20), 9.0)
        XCTAssertEqual(session.estimatedCost(tariff: 1.50), 67.5)
        XCTAssertNil(session.estimatedCost(tariff: nil))
    }

    @Test
    func testRefreshPolicyAdaptiveInterval() {
        XCTAssertEqual(RefreshPolicy.regularInterval(isCharging: false, isClimateActive: false), 300)
        XCTAssertEqual(RefreshPolicy.regularInterval(isCharging: true, isClimateActive: false), 60)
        XCTAssertEqual(RefreshPolicy.regularInterval(isCharging: false, isClimateActive: true), 60)
        XCTAssertEqual(RefreshPolicy.regularInterval(isCharging: true, isClimateActive: true), 60)
    }
}
