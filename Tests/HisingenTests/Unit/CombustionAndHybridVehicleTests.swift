import Foundation
import Testing
@testable import Hisingen

struct CombustionAndHybridVehicleTests {

    @Test
    func testPowertrainClassification() {
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "PETROL"), .ice)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "DIESEL"), .ice)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "GASOLINE"), .ice)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "ELECTRIC"), .bev)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "PETROL_PLUG_IN_HYBRID"), .phev)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "DIESEL_PLUG_IN_HYBRID"), .phev)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "PETROL_MHEV"), .mildHybrid)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "PETROL_HYBRID"), .mildHybrid)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "RECHARGE_PLUG_IN"), .phev)
    }

    @Test
    func testPowertrainProperties() {
        let ice = PowertrainType.ice
        XCTAssertTrue(ice.hasFuelRange)
        XCTAssertFalse(ice.hasElectricRange)
        XCTAssertTrue(ice.isCombustionOnly)
        XCTAssertFalse(ice.isHybrid)

        let phev = PowertrainType.phev
        XCTAssertTrue(phev.hasFuelRange)
        XCTAssertTrue(phev.hasElectricRange)
        XCTAssertFalse(phev.isCombustionOnly)
        XCTAssertTrue(phev.isHybrid)

        let mhev = PowertrainType.mildHybrid
        XCTAssertTrue(mhev.hasFuelRange)
        XCTAssertTrue(mhev.hasElectricRange)
        XCTAssertTrue(mhev.isHybrid)

        let bev = PowertrainType.bev
        XCTAssertFalse(bev.hasFuelRange)
        XCTAssertTrue(bev.hasElectricRange)
        XCTAssertTrue(bev.isElectricOnly)
        XCTAssertFalse(bev.isHybrid)
    }

    @Test
    func testVehicleStateCombinedRangeCalculations() {
        var hybridState = VehicleState(
            batteryPercentage: 80.0,
            rangeKm: 50,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 100,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .unknown,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "XC60 Recharge",
            modelYear: "2024",
            registrationNo: "HYB123",
            vin: "YV1TESTHYBRID1234",
            ownerFirstName: "Alex",
            odometerKm: 12000,
            daysToService: 240,
            distanceToServiceKm: 18000,
            serviceWarning: false,
            fluidWarnings: [],
            powertrain: .phev,
            fuelLevelPercent: 75.0,
            fuelRangeKm: 550,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
        hybridState.fuelAmountLiters = 45.0
        hybridState.averageFuelConsumptionLPer100Km = 5.2
        hybridState.isEngineRunning = false

        XCTAssertEqual(hybridState.totalCombinedRangeKm, 600)
        XCTAssertEqual(hybridState.primaryRangeKm, 600)

        var iceState = VehicleState(
            batteryPercentage: nil,
            rangeKm: nil,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: nil,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "XC90 B5",
            modelYear: "2023",
            registrationNo: "GAS123",
            vin: "YV1TESTICE123456",
            ownerFirstName: "Sam",
            odometerKm: 34000,
            daysToService: 120,
            distanceToServiceKm: 9000,
            serviceWarning: false,
            fluidWarnings: [],
            powertrain: .ice,
            fuelLevelPercent: 68.0,
            fuelRangeKm: 620,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
        iceState.fuelAmountLiters = 48.0
        iceState.averageFuelConsumptionLPer100Km = 7.4
        iceState.isEngineRunning = true

        XCTAssertEqual(iceState.totalCombinedRangeKm, 620)
        XCTAssertEqual(iceState.primaryRangeKm, 620)
        XCTAssertEqual(iceState.stateSummary.message, "Engine running")
    }

    @Test
    func testFormatIconAndBarTitleForCombustionAndHybrids() {
        let iceState = VehicleState(
            batteryPercentage: nil,
            rangeKm: nil,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: nil,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "XC40 B4",
            modelYear: "2023",
            registrationNo: "PET123",
            vin: "YV1TESTPETROL1234",
            ownerFirstName: "Pat",
            odometerKm: 15000,
            daysToService: 180,
            distanceToServiceKm: 12000,
            serviceWarning: false,
            fluidWarnings: [],
            powertrain: .ice,
            fuelLevelPercent: 74.0,
            fuelRangeKm: 650,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )

        XCTAssertEqual(Format.icon(for: iceState), "fuelpump.fill")
        XCTAssertEqual(Format.barTitle(for: iceState, style: .battery, unit: .kilometers), "74%")
        XCTAssertEqual(Format.barTitle(for: iceState, style: .batteryAndRange, unit: .kilometers), "74% · 650km")

        let phevState = VehicleState(
            batteryPercentage: 85.0,
            rangeKm: 45,
            chargingState: .charging,
            estimatedChargingTimeToFullMinutes: 45,
            chargeTargetPercentage: 100,
            chargingPowerWatts: 3700,
            chargingCurrentAmps: 16,
            chargingVoltageVolts: 230,
            chargingType: .ac,
            chargerConnection: .connected,
            availability: .available,
            modelName: "V60 Recharge",
            modelYear: "2024",
            registrationNo: "PHEV12",
            vin: "YV1TESTPHEV9876",
            ownerFirstName: "Robin",
            odometerKm: 8000,
            daysToService: 300,
            distanceToServiceKm: 22000,
            serviceWarning: false,
            fluidWarnings: [],
            powertrain: .phev,
            fuelLevelPercent: 60.0,
            fuelRangeKm: 500,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )

        XCTAssertEqual(Format.icon(for: phevState), "bolt.car.fill")
        XCTAssertEqual(Format.barTitle(for: phevState, style: .batteryAndRange, unit: .kilometers), "85% · 545km")
    }

    @Test
    func testVolvoFuelDTODecoding() throws {
        let json = """
        {
            "data": {
                "fuelAmount": { "value": 52.5, "unit": "liters" },
                "fuelLevelPercent": { "value": 78.0, "unit": "percent" },
                "distanceToEmpty": { "value": 710, "unit": "kilometers" }
            }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VolvoEnvelope<VolvoFuelDTO>.self, from: json)
        let fuel = decoded.data
        XCTAssertEqual(fuel?.liters, 52.5)
        XCTAssertEqual(fuel?.percentage, 78.0)
        XCTAssertEqual(fuel?.rangeKm, 710)
    }

    @Test
    func testVolvoStatisticsAndBrakesDecoding() throws {
        let statsJson = """
        {
            "data": {
                "tripMeterManual": { "value": 142.5 },
                "tripMeterAutomatic": { "value": 38.2 },
                "averageSpeed": { "value": 64.0 },
                "averageEnergyConsumption": { "value": 18.5 },
                "averageFuelConsumption": { "value": 2.1 },
                "electricDistance": { "value": 25600.0 },
                "fuelDistance": { "value": 12600.0 },
                "regeneratedEnergy": { "value": 3.42 }
            }
        }
        """.data(using: .utf8)!

        let decodedStats = try JSONDecoder().decode(VolvoEnvelope<VolvoStatisticsDTO>.self, from: statsJson)
        let stats = decodedStats.data
        XCTAssertEqual(stats?.electricDistance?.value, 25600.0)
        XCTAssertEqual(stats?.fuelDistance?.value, 12600.0)
        XCTAssertEqual(stats?.regeneratedEnergy?.value, 3.42)

        let brakesJson = """
        {
            "data": {
                "brakeFluidLevelWarning": { "value": "NO_WARNING" },
                "frontBrakePadStatus": { "value": "NORMAL" },
                "rearBrakePadStatus": { "value": "NORMAL" },
                "parkingBrakeStatus": { "value": "ENGAGED" }
            }
        }
        """.data(using: .utf8)!

        let decodedBrakes = try JSONDecoder().decode(VolvoEnvelope<VolvoBrakesDTO>.self, from: brakesJson)
        let brakes = decodedBrakes.data
        XCTAssertEqual(brakes?.frontBrakePadStatus?.value, "NORMAL")
        XCTAssertEqual(brakes?.rearBrakePadStatus?.value, "NORMAL")
        XCTAssertEqual(brakes?.parkingBrakeStatus?.value, "ENGAGED")
    }
}
