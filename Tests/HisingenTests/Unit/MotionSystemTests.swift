import SwiftUI
import Testing
@testable import Hisingen

/// The shared motion token system: that the tokens are ordered the way the
/// design language describes (interaction < state < ambient), that Reduce Motion
/// is resolved in one place, and that the menu-bar ambient cadence stays frugal.
@Suite(.serialized)
@MainActor
struct MotionSystemTests {

    // MARK: - Token ordering

    @Test
    func durationsRunFromInstantToDeliberate() {
        XCTAssertTrue(Motion.micro < Motion.fast)
        XCTAssertTrue(Motion.fast < Motion.standard)
        XCTAssertTrue(Motion.standard < Motion.large)
        XCTAssertTrue(Motion.large < Motion.deliberate)
        // Interaction is always quicker than a full breath.
        XCTAssertTrue(Motion.deliberate < Motion.breathCycle)
    }

    @Test
    func ambientIsSlowAndAutoreversing() {
        // A breath is measured in seconds, not fractions of one.
        XCTAssertTrue(Motion.breathCycle >= 2.0)
        // The "live" heartbeat is quicker than a breath but still unhurried.
        XCTAssertTrue(Motion.livePulseCycle < Motion.breathCycle)
        XCTAssertTrue(Motion.livePulseCycle >= 1.0)
        // Continuous rotation completes a turn in about a second and a half.
        XCTAssertTrue(Motion.spinCycle >= 1.0 && Motion.spinCycle <= 2.0)
    }

    // MARK: - Menu-bar ambient must be cheap

    @Test
    func menuBarBreathIsSlowerAndCoarserThanInPanel() {
        // The tray glyph is on screen for hours, so it breathes more slowly than
        // anything inside the panel.
        XCTAssertTrue(Motion.menuBarBreathCycle > Motion.breathCycle)

        // And it is sampled coarsely: one redraw every ~0.15 s or slower.
        let tick = Motion.menuBarBreathCycle / Double(Motion.menuBarBreathFrames)
        XCTAssertTrue(tick >= 0.15, "menu-bar breath ticks too often (\(tick)s) for a multi-hour charge")
        XCTAssertTrue(Motion.menuBarBreathFrames >= 2)

        // The completion acknowledgement is a brief dwell, not a lingering state.
        XCTAssertTrue(Motion.menuBarCompletionDwell >= 2 && Motion.menuBarCompletionDwell <= 8)
    }

    // MARK: - Reduce Motion resolves in one place

    @Test
    func resolveDropsAnimationUnderReduceMotion() {
        let original = VehicleMotionPreference.reduceMotionOverride
        defer { VehicleMotionPreference.reduceMotionOverride = original }

        VehicleMotionPreference.reduceMotionOverride = false
        XCTAssertFalse(Motion.prefersReducedMotion)
        XCTAssertNotNil(Motion.resolve(Motion.interaction))
        XCTAssertNotNil(Motion.resolve(Motion.stateChange))

        VehicleMotionPreference.reduceMotionOverride = true
        XCTAssertTrue(Motion.prefersReducedMotion)
        XCTAssertNil(Motion.resolve(Motion.interaction))
        XCTAssertNil(Motion.resolve(Motion.stateChange))
        // A cross-fade is still allowed through, so a state change is noticed.
        XCTAssertNotNil(Motion.resolveCrossfade(Motion.stateChange))
    }

    @Test
    func resolveIsANoOpWhenMotionIsAllowed() {
        let original = VehicleMotionPreference.reduceMotionOverride
        defer { VehicleMotionPreference.reduceMotionOverride = original }

        VehicleMotionPreference.reduceMotionOverride = false
        XCTAssertNotNil(Motion.resolve(Motion.entrance))
        XCTAssertNil(Motion.resolve(nil))
    }
}
