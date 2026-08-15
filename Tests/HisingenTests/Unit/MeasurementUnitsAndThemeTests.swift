import Foundation
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

        Preferences.appearanceMode = .light
        XCTAssertEqual(Preferences.appearanceMode, .light)

        Preferences.appearanceMode = .dark
        XCTAssertEqual(Preferences.appearanceMode, .dark)

        Preferences.appearanceMode = .system
        XCTAssertEqual(Preferences.appearanceMode, .system)
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
}
