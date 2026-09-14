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
        #expect(Motion.micro < Motion.fast)
        #expect(Motion.fast < Motion.standard)
        #expect(Motion.standard < Motion.large)
        #expect(Motion.large < Motion.deliberate)
        // Interaction is always quicker than a full breath.
        #expect(Motion.deliberate < Motion.breathCycle)
    }

    @Test
    func ambientIsSlowAndAutoreversing() {
        // A breath is measured in seconds, not fractions of one.
        #expect(Motion.breathCycle >= 2.0)
        // The "live" heartbeat is quicker than a breath but still unhurried.
        #expect(Motion.livePulseCycle < Motion.breathCycle)
        #expect(Motion.livePulseCycle >= 1.0)
        // Continuous rotation completes a turn in about a second and a half.
        #expect(Motion.spinCycle >= 1.0 && Motion.spinCycle <= 2.0)
    }

    // MARK: - Menu-bar ambient must be cheap

    @Test
    func menuBarBreathIsSlowerAndCoarserThanInPanel() {
        // The tray glyph is on screen for hours, so it breathes more slowly than
        // anything inside the panel.
        #expect(Motion.menuBarBreathCycle > Motion.breathCycle)

        // And it is sampled coarsely: one redraw every ~0.15 s or slower.
        let tick = Motion.menuBarBreathCycle / Double(Motion.menuBarBreathFrames)
        #expect(tick >= 0.15, "menu-bar breath ticks too often (\(tick)s) for a multi-hour charge")
        #expect(Motion.menuBarBreathFrames >= 2)

        // The completion acknowledgement is a brief dwell, not a lingering state.
        #expect(Motion.menuBarCompletionDwell >= 2 && Motion.menuBarCompletionDwell <= 8)
    }

    // MARK: - Reduce Motion resolves in one place

    @Test
    func resolveDropsAnimationUnderReduceMotion() {
        let original = VehicleMotionPreference.reduceMotionOverride
        defer { VehicleMotionPreference.reduceMotionOverride = original }

        VehicleMotionPreference.reduceMotionOverride = false
        #expect(!(Motion.prefersReducedMotion))
        #expect(Motion.resolve(Motion.interaction) != nil)
        #expect(Motion.resolve(Motion.stateChange) != nil)

        VehicleMotionPreference.reduceMotionOverride = true
        #expect(Motion.prefersReducedMotion)
        #expect(Motion.resolve(Motion.interaction) == nil)
        #expect(Motion.resolve(Motion.stateChange) == nil)
        // A cross-fade is still allowed through, so a state change is noticed.
        #expect(Motion.resolveCrossfade(Motion.stateChange) != nil)
    }

    @Test
    func resolveIsANoOpWhenMotionIsAllowed() {
        let original = VehicleMotionPreference.reduceMotionOverride
        defer { VehicleMotionPreference.reduceMotionOverride = original }

        VehicleMotionPreference.reduceMotionOverride = false
        #expect(Motion.resolve(Motion.entrance) != nil)
        #expect(Motion.resolve(nil) == nil)
    }
}
