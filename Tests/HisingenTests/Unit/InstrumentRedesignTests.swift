import SwiftUI
import Testing
@testable import Hisingen

/// The instrument redesign's contracts: the gesture physics the panel *feels* is the same
/// math these tests assert, the living overlay draws only what the car reported, and the
/// charging scene invents nothing. Render proofs sit at the bottom, because a composition
/// can be logically right and still never reach pixels.
@Suite(.serialized)
@MainActor
struct InstrumentRedesignTests {

    // MARK: - Gesture physics (G5)

    @Test
    func rubberBandResistsFurtherTheFurtherPastTheBoundary() {
        let first = InstrumentMath.rubberBandDisplacement(overshoot: 10, dimension: 300)
        let second = InstrumentMath.rubberBandDisplacement(overshoot: 40, dimension: 300)
        #expect(second > first, "more overshoot travels further, but with diminishing return")
        #expect(second < 40, "the band must never follow the pointer past the edge 1:1")
        #expect(first < 10 * 0.55 + 0.01, "within the band, displacement stays under the raw overshoot")
        #expect(InstrumentMath.rubberBandDisplacement(overshoot: 10, dimension: 0) == 0,
                "a degenerate dimension must not divide by zero")
    }

    @Test
    func momentumProjectionMatchesTheExponentialDecayForm() {
        // Apple's projection: (v/1000)·d/(1−d) with d = 0.998 → v/1000 × 499.
        let projected = InstrumentMath.momentumProjection(velocity: 1000)
        #expect(abs(projected - 499.0) < 0.5)
        #expect(InstrumentMath.momentumProjection(velocity: 0) == 0)
        #expect(InstrumentMath.momentumProjection(velocity: -1000) < 0,
                "a reversed flick projects backwards")
    }

    @Test
    func tabSwipeLandsWhereTheVelocityPoints() {
        // A slow drag just past half of one page lands on the next tab.
        let dragged = InstrumentMath.projectedTab(
            currentIndex: 1, count: 4, translation: -140, releaseVelocity: 0, pageWidth: 240)
        #expect(dragged == 2)
        // A short, fast flick commits to the next tab even though the finger barely moved;
        // velocity steers the step, it never skips multiple tabs.
        let flicked = InstrumentMath.projectedTab(
            currentIndex: 1, count: 4, translation: -30, releaseVelocity: -1400, pageWidth: 240)
        #expect(flicked == 2)
        // A reversed flick returns.
        #expect(InstrumentMath.projectedTab(
            currentIndex: 1, count: 4, translation: 30, releaseVelocity: 1400, pageWidth: 240) == 0)
        // A settled drag with no velocity stays put.
        #expect(InstrumentMath.projectedTab(
            currentIndex: 1, count: 4, translation: -40, releaseVelocity: 0, pageWidth: 240) == 1)
        // A strong flick at the edge does not leave the real tab range.
        #expect(InstrumentMath.projectedTab(
            currentIndex: 3, count: 4, translation: -500, releaseVelocity: -3000, pageWidth: 240) == 3)
        // Degenerate inputs refuse rather than guess.
        #expect(InstrumentMath.projectedTab(currentIndex: 0, count: 0, translation: -10, releaseVelocity: 0, pageWidth: 240) == nil)
        #expect(InstrumentMath.projectedTab(currentIndex: 0, count: 3, translation: -10, releaseVelocity: 0, pageWidth: 0) == nil)
    }

    @Test
    func pullRefreshCommitsOnDistanceOrOnDownwardMomentum() {
        #expect(InstrumentMath.pullRefreshShouldCommit(dragDistance: 60, releaseVelocity: 0))
        #expect(InstrumentMath.pullRefreshShouldCommit(dragDistance: 30, releaseVelocity: 400),
                "a short pull with clear downward intent still commits")
        #expect(!InstrumentMath.pullRefreshShouldCommit(dragDistance: 30, releaseVelocity: 0),
                "position alone below the threshold never commits")
        #expect(!InstrumentMath.pullRefreshShouldCommit(dragDistance: 60, releaseVelocity: 0, threshold: 100),
                "the threshold is the contract, not the caller's hope")
    }

    // MARK: - Charge projection (G3): empty over deceptive

    @Test
    func projectionReportsTimeAndRangeOnlyFromRealInputs() {
        let projection = InstrumentMath.chargeProjection(
            currentPercent: 40, targetPercent: 80,
            availableEnergyKwh: 30, reportedCapacityKwh: 75,
            averageConsumptionKwhPer100Km: 20, powerKw: 11
        )
        // 40% of 75 kWh at 20 kWh/100km → 40 added points = 30 kWh = 150 km; at 11 kW ≈ 164 min.
        #expect(projection?.minutesToTarget == 164)
        #expect(projection?.addedRangeKm == 150)
        #expect(projection?.capacityIsDerived == false)
    }

    @Test
    func projectionDerivesCapacityOnlyWhenItMustAndSaysSo() {
        // Derived capacity, power present: the time figure lands and says its capacity was
        // derived; no consumption reading means no range claim.
        let projection = InstrumentMath.chargeProjection(
            currentPercent: 50, targetPercent: 70,
            availableEnergyKwh: 30, reportedCapacityKwh: nil,
            averageConsumptionKwhPer100Km: nil, powerKw: 11
        )
        // Derived capacity = 30/50% = 60 kWh; 20% of that at 11 kW ≈ 65 min.
        #expect(projection?.capacityIsDerived == true)
        #expect(projection?.minutesToTarget == 65)
        #expect(projection?.addedRangeKm == nil)

        // With no figure the projection can support at all, there is no projection.
        #expect(InstrumentMath.chargeProjection(
            currentPercent: 50, targetPercent: 70,
            availableEnergyKwh: 30, reportedCapacityKwh: nil,
            averageConsumptionKwhPer100Km: nil, powerKw: nil
        ) == nil)
    }

    @Test
    func projectionRefusesWhatItCannotSupport() {
        // Target below the current level is not a charge.
        #expect(InstrumentMath.chargeProjection(
            currentPercent: 80, targetPercent: 60, availableEnergyKwh: 30,
            reportedCapacityKwh: nil, averageConsumptionKwhPer100Km: nil, powerKw: 11) == nil)
        // No readings at all: no numbers, ever.
        #expect(InstrumentMath.chargeProjection(
            currentPercent: nil, targetPercent: 80, availableEnergyKwh: nil,
            reportedCapacityKwh: nil, averageConsumptionKwhPer100Km: nil, powerKw: nil) == nil)
        // A reading of "0% available" cannot derive a capacity without dividing into nonsense.
        #expect(InstrumentMath.chargeProjection(
            currentPercent: 10, targetPercent: 80, availableEnergyKwh: 0,
            reportedCapacityKwh: nil, averageConsumptionKwhPer100Km: nil, powerKw: nil) == nil)
    }

    // MARK: - Living layer (G2)

    private func exterior(_ readings: [OpeningReading], locked: Bool? = true) -> ExteriorSnapshot {
        ExteriorSnapshot(openings: readings, isLocked: locked, alarmTriggered: nil)
    }

    @Test
    func openingMarkersDrawOnlyWhatTheCarReportedOpen() {
        let pairedDoors = exterior([
            OpeningReading(opening: .frontLeftDoor, state: .open),
            OpeningReading(opening: .frontRightDoor, state: .open),
            OpeningReading(opening: .rearLeftDoor, state: .closed),
        ])
        // A side profile has one place per door pair.
        let markers = LivingVehicleView.openingMarkers(from: pairedDoors)
        #expect(markers == [.frontLeftDoor])

        let ajarHood = exterior([
            OpeningReading(opening: .hood, state: .ajar),
            OpeningReading(opening: .tailgate, state: .open),
        ])
        #expect(LivingVehicleView.openingMarkers(from: ajarHood) == [.hood, .tailgate])

        // An unrecognised token is not a state the layer vouches for.
        let allClosed = exterior([
            OpeningReading(opening: .frontLeftDoor, state: .closed),
            OpeningReading(opening: .hood, state: .unknown),
        ])
        #expect(LivingVehicleView.openingMarkers(from: allClosed).isEmpty)
        #expect(LivingVehicleView.openingMarkers(from: nil).isEmpty)
    }

    // MARK: - Tokens (G1)

    @Test
    func displayTiersScaleWithTheReaderAndTheDensityPreset() {
        #expect(HisingenTheme.TypeTier.display.baseSize == 28)
        #expect(HisingenTheme.TypeTier.displayLarge.baseSize == 44)
        #expect(HisingenTheme.TypeTier.displayLarge.textStyle == .largeTitle,
                "the focal figures scale with the reader's text-size setting")
    }

    // MARK: - Render proofs (G2, G7): the compositions reach real pixels

    private func render<T: View>(_ view: T, width: CGFloat = 300, height: CGFloat = 180) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 1
        return try #require(renderer.cgImage, "the composition produced no image")
    }

    @Test
    func livingVehicleLayerRendersOpeningsAndCharge() throws {
        var state = vehicle(vin: "RENDER-VIN", battery: 62, rangeKm: 260,
                            odometerKm: 12_000, fetchedAt: Date(), reportedAt: Date())
        state.exteriorStatus = exterior([
            OpeningReading(opening: .frontLeftDoor, state: .open),
            OpeningReading(opening: .hood, state: .ajar),
        ])
        let withOpenings = try render(LivingVehicleView(state: state))
        #expect(withOpenings.width == 300)

        state.exteriorStatus = exterior([OpeningReading(opening: .frontLeftDoor, state: .closed)])
        state.energy.chargingState = .charging
        let charging = try render(LivingVehicleView(state: state))
        #expect(charging.width == 300)

        // The resting overlay is the honest empty one: it still renders, drawing nothing.
        state.exteriorStatus = nil
        state.energy.chargingState = .idle
        let resting = try render(LivingVehicleView(state: state))
        #expect(resting.width == 300)
    }

    @Test
    func chargingSceneRendersTheCarEstimateAndNothingInvented() throws {
        var state = vehicle(vin: "RENDER-VIN", battery: 62, rangeKm: 260,
                            odometerKm: 12_000, fetchedAt: Date(), reportedAt: Date())
        state.energy.chargingState = .charging
        state.energy.estimatedTimeToFullMinutes = 41
        state.energy.powerWatts = 11_400
        state.energy.targetPercentage = 80
        let scene = try render(ChargingSessionScene(state: state))
        #expect(scene.width == 300)

        // Without the car's estimate the scene has no headline to draw: the strip renders
        // with support figures only, never an invented estimate.
        state.energy.estimatedTimeToFullMinutes = nil
        let estimateless = try render(ChargingSessionScene(state: state))
        #expect(estimateless.width == 300)
    }

    @Test
    func pullToRefreshOverlayRendersAtRestAndArmed() throws {
        let atRest = try render(PullToRefreshOverlay(pullDistance: 0, threshold: 56))
        #expect(atRest.width == 300)
        let armed = try render(PullToRefreshOverlay(pullDistance: 56, threshold: 56))
        #expect(armed.width == 300)
    }

    @Test
    func reorderPersistsThroughTheCompositionMove() {
        // The drop delegate's mutation is the composition's own "put this where that is";
        // the storage round-trip is the contract the reorder depends on.
        var composition = TabComposition()
        composition.setItems([.vehicleHero, .vehicleCharging, .vehicleReadiness],
                             for: TabRef.custom("reorder-test"))
        composition.move(.vehicleCharging, onto: .vehicleHero, in: TabRef.custom("reorder-test"))
        let order = composition.items(for: TabRef.custom("reorder-test"))
        #expect(order.first == .vehicleCharging)
        #expect(order.count == 3, "a move relocates, it never duplicates")
    }
}
