import Foundation
import Testing
@testable import Hisingen

struct StatisticsTests {

    @Test
    func testMedianOddAndEvenCounts() {
        XCTAssertEqual(Statistics.median([]), nil)
        XCTAssertEqual(Statistics.median([5]), 5)
        XCTAssertEqual(Statistics.median([3, 1, 2]), 2)
        XCTAssertEqual(Statistics.median([1, 2, 3, 4]) ?? 0, 2.5, accuracy: 0.0001)
    }

    @Test
    func testPercentileBoundsAndMidpoint() {
        let values = [10.0, 20, 30, 40, 50]
        XCTAssertEqual(Statistics.percentile(values, 0) ?? 0, 10, accuracy: 0.0001)
        XCTAssertEqual(Statistics.percentile(values, 100) ?? 0, 50, accuracy: 0.0001)
        XCTAssertEqual(Statistics.percentile(values, 50) ?? 0, 30, accuracy: 0.0001)
        XCTAssertNil(Statistics.percentile([], 50))
    }

    @Test
    func testLinearRegressionRecoversKnownLine() throws {
        // y = 2x + 1
        let points: [(x: Double, y: Double)] = (0..<10).map { (x: Double($0), y: Double($0) * 2 + 1) }
        let fit = try XCTUnwrap(Statistics.linearRegression(points))
        XCTAssertEqual(fit.slope, 2, accuracy: 0.0001)
        XCTAssertEqual(fit.intercept, 1, accuracy: 0.0001)
        XCTAssertEqual(fit.value(at: 5), 11, accuracy: 0.0001)
    }

    @Test
    func testLinearRegressionNeedsVaryingX() {
        XCTAssertNil(Statistics.linearRegression([(x: 1, y: 1)]))
        XCTAssertNil(Statistics.linearRegression([(x: 5, y: 1), (x: 5, y: 9)]))
    }

    @Test
    func testPearsonCorrelationPerfectNegative() {
        let pairs: [(Double, Double)] = (0..<10).map { (Double($0), Double(10 - $0)) }
        XCTAssertEqual(Statistics.pearsonCorrelation(pairs) ?? 0, -1, accuracy: 0.0001)
    }

    @Test
    func testPearsonCorrelationNeedsSpread() {
        XCTAssertNil(Statistics.pearsonCorrelation([(1, 1), (1, 5)]))
    }

    @Test
    func testMovingAverageSmoothsAndKeepsLength() {
        let values = [1.0, 2, 3, 4, 5]
        let smoothed = Statistics.movingAverage(values, windowSize: 2)
        XCTAssertEqual(smoothed.count, values.count)
        XCTAssertEqual(smoothed[0], 1, accuracy: 0.0001) // window not yet full
        XCTAssertEqual(smoothed[1], 1.5, accuracy: 0.0001)
        XCTAssertEqual(smoothed[4], 4.5, accuracy: 0.0001)
    }

    @Test
    func testMovingAveragePassthroughForTrivialWindow() {
        let values = [3.0, 1, 4]
        XCTAssertEqual(Statistics.movingAverage(values, windowSize: 1), values)
        XCTAssertEqual(Statistics.movingAverage(values, windowSize: 0), values)
    }
}
