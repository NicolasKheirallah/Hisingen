import Foundation
import Testing
@testable import Hisingen

@Suite("Consolidated Export Helpers")
struct ChargingHistoryExportTests {
    @Test("CSV export renders one row per session with stable column order")
    func testCSVShape() {
        let session = ChargingSession(
            id: UUID(),
            vin: "YSMTEST0000000001",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_003_600),
            startBatteryPercentage: 40,
            endBatteryPercentage: 80,
            kwhDelivered: 12.5,
            peakPowerWatts: 11_000,
            cost: nil,
            targetPercentage: nil,
            samples: []
        )
        let csv = ChargingHistoryExport.csv(sessions: [session], tariffPricePerKwh: 2, currencySymbol: "kr")
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "Date,Start Battery %,End Battery %,Battery Added %,kWh Delivered,Peak Power (kW),Duration (min),Estimated Cost,Currency")
        let cells = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(cells.count == 9)
        #expect(cells[1] == "40.0")
        #expect(cells[2] == "80.0")
        #expect(cells[3] == "40.0")
        #expect(cells[4] == "12.5")
        #expect(cells[8] == "kr")
    }

    @Test("Unit conversion constants agree with DistanceUnit behaviour")
    func testUnitConversionConstants() {
        // The shared factor must match the enum's own conversion table.
        let km = 100
        let viaUnit = Double(DistanceUnit.miles.convert(km: km))
        let viaConstant = Double(km) * UnitConversion.kilometersPerMile
        #expect(abs(viaUnit - viaConstant.rounded()) < 0.5)
    }
}
