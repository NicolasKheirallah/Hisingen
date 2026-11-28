import Foundation
import Testing
@testable import Hisingen

/// The segmentation rules are asserted directly: no database, no hand-written INSERT, and no
/// dependence on when a test happens to run. That is the point of the rules living here rather
/// than inside the ledger's query method.
struct TripSegmentationTests {

    private let vin = "TRIP-SEGMENTATION-VIN"
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    @Test
    func consecutiveMovementBecomesOneTrip() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 1_000),
            reading(id: 2, minute: 10, odometer: 1_010),
            reading(id: 3, minute: 20, odometer: 1_020),
        ], vin: vin, limit: 10)

        #expect(trips.count == 1)
        #expect(trips.first?.distanceKm == 20)
        #expect(trips.first?.startedAt == start)
        #expect(trips.first?.endedAt == start.addingTimeInterval(20 * 60))
    }

    @Test
    func aGapPastTheLimitEndsTheTrip() {
        // 46 minutes between the second and third reading: past the 45-minute segmentation gap,
        // so the first two readings are one trip and the third is not a trip on its own.
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 1_000),
            reading(id: 2, minute: 10, odometer: 1_010),
            reading(id: 3, minute: 56, odometer: 1_020),
        ], vin: vin, limit: 10)

        #expect(trips.count == 1)
        #expect(trips.first?.distanceKm == 10)
        #expect(trips.first?.endedAt == start.addingTimeInterval(10 * 60))
    }

    @Test
    func movementBelowTheFloorIsNoise() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 1_000),
            reading(id: 2, minute: 10, odometer: 1_000.02),
        ], vin: vin, limit: 10)

        #expect(trips.isEmpty)
    }

    @Test
    func anImplausibleOdometerDeltaFallsBackToTheTripMeter() {
        // The odometer jumps 5,000 km – a rollover or a misread – while the automatic trip
        // meter moved a believable 12 km, so the trip meter supplies the distance.
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 1_000, automatic: 100),
            reading(id: 2, minute: 10, odometer: 6_000, automatic: 112),
        ], vin: vin, limit: 10)

        #expect(trips.first?.distanceKm == 12)
    }

    @Test
    func theLimitKeepsTheNewestTrips() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 1_000),
            reading(id: 2, minute: 10, odometer: 1_010),
            reading(id: 3, minute: 56, odometer: 1_020),
            reading(id: 4, minute: 66, odometer: 1_030),
            reading(id: 5, minute: 112, odometer: 1_040),
            reading(id: 6, minute: 122, odometer: 1_050),
        ], vin: vin, limit: 2)

        #expect(trips.count == 2)
        // Newest first, which is the order every caller renders.
        #expect(trips.first?.startedAt == start.addingTimeInterval(112 * 60))
        #expect(trips.last?.startedAt == start.addingTimeInterval(56 * 60))
    }

    @Test func lockingSegmentSourcePreventsOdometerAndTripMeterDoubleCounting() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 1_000, automatic: 1.0),
            reading(id: 2, minute: 5, odometer: 1_000, automatic: 1.4),
            reading(id: 3, minute: 10, odometer: 1_001, automatic: 2.0)
        ], vin: vin, limit: 10)

        #expect(trips.count == 1)
        #expect(abs((trips.first?.distanceKm ?? 0) - 1.0) < 0.001)
    }

    @Test func aParkedReadingSeparatesTripsWithoutDoubleCountingTheNextOdometerTick() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 100, automatic: 0),
            reading(id: 2, minute: 5, odometer: 100, automatic: 0.4),
            reading(id: 3, minute: 10, odometer: 100, automatic: 0.4),
            reading(id: 4, minute: 15, odometer: 101, automatic: 1)
        ], vin: vin, limit: 10)

        #expect(trips.count == 2)
        #expect(trips.map(\.id) == ["3-4", "1-2"])
        #expect(abs(trips.reduce(0) { $0 + $1.distanceKm } - 1) < 0.001)
    }

    @Test func aResetTripMeterLetsTheOdometerMeasureTheNextInterval() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: nil, automatic: 20),
            reading(id: 2, minute: 5, odometer: 105, automatic: 25),
            reading(id: 3, minute: 10, odometer: 108, automatic: 3)
        ], vin: vin, limit: 10)

        #expect(trips.map(\.distanceKm) == [3, 5])
    }

    @Test func cumulativeAutomaticTripMeterSuppressesRollingAverageConsumption() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 5_000, automatic: 420.0, consumption: 18.2),
            reading(id: 2, minute: 10, odometer: 5_005, automatic: 425.0, consumption: 18.4)
        ], vin: vin, limit: 10)

        let single = trips.first
        #expect(single?.distanceKm == 5)
        #expect(single?.averageConsumption == nil)
    }

    @Test(arguments: [nil, 0] as [Double?])
    func aMissingOrResetTripCounterDoesNotQualifyTheStoredConsumption(automaticStart: Double?) {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 100, automatic: automaticStart, consumption: 19),
            reading(id: 2, minute: 5, odometer: 105, automatic: automaticStart.map { _ in 5 }, consumption: 19)
        ], vin: vin, limit: 10)

        #expect(trips.first?.distanceKm == 5)
        #expect(trips.first?.averageConsumption == nil)
    }

    @Test func reconciledGapsPreserveOdometerDistanceAcrossSleepIntervals() {
        let trips = TripSegmentation.trips(from: [
            reading(id: 1, minute: 0, odometer: 1_000),
            reading(id: 2, minute: 10, odometer: 1_010),
            reading(id: 3, minute: 190, odometer: 1_045),
            reading(id: 4, minute: 205, odometer: 1_055)
        ], vin: vin, limit: 10, includeReconciledGaps: true)

        #expect(trips.count == 3)
        let totalDistance = trips.reduce(0.0) { $0 + $1.distanceKm }
        #expect(totalDistance == 55)
        let gapTrip = trips.first { $0.isReconciledGap }
        #expect(gapTrip?.distanceKm == 35)
        #expect(gapTrip?.averageConsumption == nil)
    }

    private func reading(
        id: Int64, minute: Int, odometer: Double?,
        automatic: Double? = nil, consumption: Double? = 16, temperature: Double? = 20
    ) -> HistoricalTelemetryRecord {
        HistoricalTelemetryRecord(
            id: id, vin: vin, timestamp: start.addingTimeInterval(Double(minute * 60)),
            odometerKm: odometer, tripManualKm: nil, tripAutomaticKm: automatic,
            averageConsumption: consumption, averageConsumptionUnit: "kwh",
            ambientTemperatureCelsius: temperature, latitude: nil, longitude: nil
        )
    }
}
