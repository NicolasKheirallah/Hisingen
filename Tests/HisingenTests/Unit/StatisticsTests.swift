import Foundation
import Testing
@testable import Hisingen

struct StatisticsTests {

    @Test
    func testMedianOddAndEvenCounts() {
        #expect(Statistics.median([]) == nil)
        #expect(Statistics.median([5]) == 5)
        #expect(Statistics.median([3, 1, 2]) == 2)
        #expect(abs((Statistics.median([1, 2, 3, 4]) ?? 0) - 2.5) <= 0.0001)
    }

    @Test
    func testPercentileBoundsAndMidpoint() {
        let values = [10.0, 20, 30, 40, 50]
        #expect(abs((Statistics.percentile(values, 0) ?? 0) - 10) <= 0.0001)
        #expect(abs((Statistics.percentile(values, 100) ?? 0) - 50) <= 0.0001)
        #expect(abs((Statistics.percentile(values, 50) ?? 0) - 30) <= 0.0001)
        #expect(Statistics.percentile([], 50) == nil)
    }

    @Test
    func testLinearRegressionRecoversKnownLine() throws {
        // y = 2x + 1
        let points: [(x: Double, y: Double)] = (0..<10).map { (x: Double($0), y: Double($0) * 2 + 1) }
        let fit = try #require(Statistics.linearRegression(points))
        #expect(abs(fit.slope - 2) <= 0.0001)
        #expect(abs(fit.intercept - 1) <= 0.0001)
        #expect(abs(fit.value(at: 5) - 11) <= 0.0001)
    }

    @Test
    func testLinearRegressionNeedsVaryingX() {
        #expect(Statistics.linearRegression([(x: 1, y: 1)]) == nil)
        #expect(Statistics.linearRegression([(x: 5, y: 1), (x: 5, y: 9)]) == nil)
    }

    @Test
    func testPearsonCorrelationPerfectNegative() {
        let pairs: [(Double, Double)] = (0..<10).map { (Double($0), Double(10 - $0)) }
        #expect(abs((Statistics.pearsonCorrelation(pairs) ?? 0) - -1) <= 0.0001)
    }

    @Test
    func testPearsonCorrelationNeedsSpread() {
        #expect(Statistics.pearsonCorrelation([(1, 1), (1, 5)]) == nil)
    }

    @Test
    func testMovingAverageSmoothsAndKeepsLength() {
        let values = [1.0, 2, 3, 4, 5]
        let smoothed = Statistics.movingAverage(values, windowSize: 2)
        #expect(smoothed.count == values.count)
        #expect(abs(smoothed[0] - 1) <= 0.0001) // window not yet full
        #expect(abs(smoothed[1] - 1.5) <= 0.0001)
        #expect(abs(smoothed[4] - 4.5) <= 0.0001)
    }

    @Test
    func testMovingAveragePassthroughForTrivialWindow() {
        let values = [3.0, 1, 4]
        #expect(Statistics.movingAverage(values, windowSize: 1) == values)
        #expect(Statistics.movingAverage(values, windowSize: 0) == values)
    }
}
