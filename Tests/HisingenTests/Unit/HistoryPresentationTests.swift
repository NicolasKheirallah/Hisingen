import Foundation
import Testing
@testable import Hisingen

@Suite("History presentation")
struct HistoryPresentationTests {
    @Test("Detected trips render five at a time and clamp page bounds")
    func tripPagination() {
        let values = Array(0..<12)
        #expect(HistoryPagination.pageCount(itemCount: values.count) == 3)
        #expect(Array(HistoryPagination.page(of: values, index: 0)) == [0, 1, 2, 3, 4])
        #expect(Array(HistoryPagination.page(of: values, index: 1)) == [5, 6, 7, 8, 9])
        #expect(Array(HistoryPagination.page(of: values, index: 99)) == [10, 11])
        #expect(HistoryPagination.pageCount(itemCount: 0) == 0)
    }

    @Test("Charging curves split instead of connecting across observation gaps")
    func chargingCurveGaps() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let samples = [
            ChargingSample(timestamp: start, batteryPercentage: 20, powerWatts: 7_000),
            ChargingSample(timestamp: start.addingTimeInterval(10 * 60), batteryPercentage: 22, powerWatts: 7_000),
            ChargingSample(timestamp: start.addingTimeInterval(30 * 60), batteryPercentage: 26, powerWatts: 7_000),
            ChargingSample(timestamp: start.addingTimeInterval(45 * 60), batteryPercentage: 29, powerWatts: 7_000)
        ]

        let segments = ChargingCharts.contiguousSegments(samples)
        #expect(segments.map(\.count) == [2, 2])
        let gap = try #require(ChargingCharts.gaps(in: samples).first)
        #expect(gap.startedAt == samples[1].timestamp)
        #expect(gap.endedAt == samples[2].timestamp)
    }
}
