import Foundation
import Testing
@testable import Hisingen

struct HandoverPackBuilderTests {
    private let vin = "YV1ZB2345K1234567"
    private let registration = "ZX12ABC"
    private let generatedAt = Calendar.current.date(
        from: DateComponents(year: 2026, month: 10, day: 31, hour: 12)
    ) ?? Date()

    @Test("The pack holds the summary, both CSV exports and the factory passport")
    func packContainsExpectedFiles() throws {
        let pack = HandoverPackBuilder.build(input())

        #expect(pack.files.map(\.name) == [
            "summary.html", "charging-sessions.csv", "trips.csv", "factory-passport.csv"
        ])
        let summary = try contents(of: "summary.html", in: pack)
        #expect(summary.contains("<!doctype html>"))
        #expect(summary.contains("Charging sessions recorded"))
        #expect(summary.contains("Checklist"))
        let charging = try contents(of: HandoverPackBuilder.chargingSessionsFileName, in: pack)
        // Header plus one row per session.
        #expect(charging.split(separator: "\n").count == 3)
    }

    @Test("The folder is named after the model and the date, with no VIN")
    func folderNameCarriesModelAndDate() {
        let pack = HandoverPackBuilder.build(input())

        #expect(pack.folderName == "Hisingen Handover Polestar 2 2026-10-31")
        #expect(!pack.folderName.contains(vin))
    }

    @Test("Without a model name the folder falls back to a generic label and keeps path separators out")
    func folderNameFallsBackAndSanitises() {
        #expect(HandoverPackBuilder.folderName(model: nil, generatedAt: generatedAt)
            == "Hisingen Handover Vehicle 2026-10-31")
        #expect(HandoverPackBuilder.folderName(model: "Polestar/2", generatedAt: generatedAt)
            == "Hisingen Handover Polestar 2 2026-10-31")
    }

    @Test("A calculated battery estimate is labelled as Hisingen's estimate, never as a measurement")
    func batteryEstimateIsLabelled() throws {
        let pack = HandoverPackBuilder.build(input(battery: estimate()))
        let summary = try contents(of: "summary.html", in: pack)

        #expect(summary.contains("Battery health (Hisingen estimate)"))
        #expect(summary.contains("not measured by the car's battery system"))
        #expect(summary.contains("Confidence"))
        #expect(summary.contains("Lower. Only one method was available."))
    }

    @Test("Two agreeing methods are described as higher confidence")
    func fusedEstimateReportsHigherConfidence() throws {
        let fused = estimate(method: BatteryHealthEstimator.fusedMethod)
        let summary = try contents(of: "summary.html", in: HandoverPackBuilder.build(input(battery: fused)))

        #expect(summary.contains("Higher. Range and charging sessions gave similar results."))
    }

    @Test("With no calculated estimate, the battery row says so and shows no percentage")
    func missingEstimateIsNotReportedAsZero() throws {
        let summary = try contents(of: "summary.html", in: HandoverPackBuilder.build(input(battery: nil)))

        #expect(summary.contains("has not calculated a state of health yet"))
        #expect(!summary.contains("Calculated state of health"))
    }

    @Test("Absent identity values show as not reported")
    func absentValuesAreNotReported() throws {
        var values = input()
        values.odometerKm = nil
        let summary = try contents(of: "summary.html", in: HandoverPackBuilder.build(values))

        #expect(summary.contains("<dt>Odometer</dt><dd>Not reported</dd>"))
    }

    @Test("VIN and registration are omitted from every file when the box is not ticked")
    func identifiersOmittedWhenUnticked() throws {
        let pack = HandoverPackBuilder.build(input(includesIdentifiers: false))

        for file in pack.files {
            #expect(!file.contents.contains(vin), "\(file.name) contains the VIN")
            #expect(!file.contents.contains(registration), "\(file.name) contains the registration")
        }
        let passport = try contents(of: HandoverPackBuilder.passportFileName, in: pack)
        #expect(!passport.contains("VIN"))
        #expect(!passport.contains("Battery Pack Serial"))
    }

    @Test("VIN and registration appear when the box is ticked")
    func identifiersIncludedWhenTicked() throws {
        let pack = HandoverPackBuilder.build(input(includesIdentifiers: true))

        #expect(try contents(of: "summary.html", in: pack).contains(vin))
        #expect(try contents(of: HandoverPackBuilder.passportFileName, in: pack).contains(registration))
        #expect(try contents(of: HandoverPackBuilder.chargingSessionsFileName, in: pack).hasPrefix("VIN,"))
    }

    @Test("No coordinates or location names are written, even when trips and sessions carry them")
    func noCoordinatesOrLocationHistory() throws {
        let pack = HandoverPackBuilder.build(input(includesIdentifiers: true))
        let everything = pack.files.map(\.contents).joined(separator: "\n")

        #expect(!everything.contains("57.70"))
        #expect(!everything.contains("11.97"))
        #expect(!everything.contains("Latitude"))
        #expect(!everything.contains("Longitude"))
        #expect(!everything.contains("Location"))
    }

    @Test("Charging totals count the sessions and the energy they delivered")
    func chargingSummaryCountsSessions() throws {
        let summary = try contents(of: "summary.html", in: HandoverPackBuilder.build(input()))

        #expect(summary.contains("Charging sessions recorded</dt><dd>2</dd>"))
        #expect(summary.contains("Energy delivered in these sessions"))
    }

    @Test("Factory identity is not written when nothing is known about the car")
    func passportOmittedWithoutFactoryData() {
        var values = input()
        values.modelName = nil
        values.modelYear = nil
        values.pno34 = nil
        values.buildWeek = nil
        values.exteriorPaint = nil
        values.upholstery = nil
        values.market = nil
        values.equipment = []
        values.batterySerial = nil

        let pack = HandoverPackBuilder.build(values)

        #expect(!pack.files.contains { $0.name == HandoverPackBuilder.passportFileName })
    }

    @Test("The checklist lists the manufacturer-side steps and the Hisingen erase step as text")
    func checklistNamesEachStep() throws {
        let summary = try contents(of: "summary.html", in: HandoverPackBuilder.build(input()))

        #expect(summary.contains("Remove the car from your Polestar/Volvo app account"))
        #expect(summary.contains("Factory reset the car's infotainment"))
        #expect(summary.contains("Remove digital keys and paired phones"))
        #expect(summary.contains("End plug and charge contracts"))
        #expect(summary.contains("Sign out of Hisingen and erase local data for this car"))
        #expect(summary.contains("In the Polestar or Volvo app."))
    }

    // MARK: - Fixtures

    private func contents(of name: String, in pack: HandoverPack) throws -> String {
        let file = pack.files.first(where: { $0.name == name })
        return try #require(file).contents
    }

    private func estimate(method: String = BatteryHealthEstimator.fullChargeRangeMethod) -> BatteryHealthEstimate {
        BatteryHealthEstimate(
            stateOfHealthPercent: 92.4,
            rawStateOfHealthPercent: 92.4,
            degradationPercent: 7.6,
            estimatedUsableCapacityKwh: 59.1,
            referenceUsableCapacityKwh: 64,
            fullChargeRangeKm: 370,
            wltpReferenceRangeKm: 400,
            recordedAt: generatedAt,
            isRemembered: false,
            method: method
        )
    }

    private func input(
        battery: BatteryHealthEstimate? = nil,
        includesIdentifiers: Bool = false
    ) -> HandoverPackInput {
        HandoverPackInput(
            modelName: "Polestar 2",
            modelYear: "2024",
            vin: vin,
            registrationNo: registration,
            internalVehicleIdentifier: "internal-123",
            pno34: "PNO-1",
            buildWeek: "2024-W12",
            exteriorPaint: "Thunder",
            upholstery: "Charcoal",
            market: "SE",
            batterySerial: "BATT-SERIAL-9",
            equipment: [.init(title: "Drivetrain", value: "AWD")],
            includesIdentifiers: includesIdentifiers,
            odometerKm: 48_210,
            distanceUnit: .kilometers,
            batteryEstimate: battery,
            service: ServiceSnapshot(daysToService: 120, distanceToServiceKm: 9_000),
            chargingSessions: [
                ChargingSession(
                    id: UUID(), vin: vin,
                    startDate: generatedAt.addingTimeInterval(-86_400 * 3),
                    endDate: generatedAt.addingTimeInterval(-86_400 * 3 + 3_600),
                    startBatteryPercentage: 20, endBatteryPercentage: 80,
                    kwhDelivered: 38.5, peakPowerWatts: 50_000, cost: 12.5
                ),
                ChargingSession(
                    id: UUID(), vin: vin,
                    startDate: generatedAt.addingTimeInterval(-86_400 * 10),
                    endDate: generatedAt.addingTimeInterval(-86_400 * 10 + 7_200),
                    startBatteryPercentage: 30, endBatteryPercentage: 90,
                    kwhDelivered: 36, peakPowerWatts: nil, cost: nil
                )
            ],
            trips: [
                TripHistoryEntry(
                    id: "trip-1", vin: vin,
                    startedAt: generatedAt.addingTimeInterval(-7_200),
                    endedAt: generatedAt.addingTimeInterval(-6_000),
                    distanceKm: 14.2, averageConsumption: 16.1, ambientTemperatureCelsius: 7,
                    startLatitude: 57.7089, startLongitude: 11.9746,
                    endLatitude: 57.6900, endLongitude: 11.9400
                )
            ],
            lastReadingAt: generatedAt.addingTimeInterval(-600),
            generatedAt: generatedAt
        )
    }
}
