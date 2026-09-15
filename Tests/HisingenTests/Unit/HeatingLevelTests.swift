import Foundation
import Testing
@testable import Hisingen

/// The heating ladder both controls step along.
///
/// The seat control used to cycle one way with no way to step down, and the steering wheel jumped
/// straight to level 3, destroying whatever level was set. Off was not a stop either of them could
/// reach deliberately.
@MainActor
struct HeatingLevelTests {

    @Test
    func everyStepUpAndDownIsReversible() {
        for level in HeatingLevel.steps {
            for delta in [1, -1] {
                let moved = HeatingLevel.stepping(from: level, by: delta)
                let back = HeatingLevel.stepping(from: moved, by: -delta)
                // Reversing a step that stayed on the ladder returns to where it started.
                if moved != level {
                    #expect(back == level, "\(level) \(delta) did not come back")
                }
            }
        }
    }

    @Test
    func offIsTheBottomStopAndDoesNotWrap() {
        #expect(HeatingLevel.stepping(from: .off, by: -1) == .off)
        #expect(HeatingLevel.stepping(from: .level1, by: -1) == .off)
    }

    @Test
    func theTopLevelIsAStopRatherThanAWrapToOff() {
        // The seat control's one-way cycle went level 3 → off, which is how the level got destroyed
        // by a reader trying to reach level 2.
        #expect(HeatingLevel.stepping(from: .level3, by: 1) == .level3)
        #expect(HeatingLevel.stepping(from: .level2, by: 1) == .level3)
    }

    @Test
    func everyLevelIsReachableFromEveryOtherByStepping() {
        for from in HeatingLevel.steps {
            for to in HeatingLevel.steps {
                var level = from
                var hops = 0
                while level != to, hops < 10 {
                    level = HeatingLevel.stepping(from: level, by: level.rawValue < to.rawValue ? 1 : -1)
                    hops += 1
                }
                #expect(level == to, "\(from) could not reach \(to)")
            }
        }
    }

    @Test
    func anUnreportedLevelStepsOnRatherThanStayingStuck() {
        // `unspecified` means the vehicle has not reported, which is not a rung on the ladder.
        #expect(!HeatingLevel.steps.contains(.unspecified))
        #expect(HeatingLevel.stepping(from: .unspecified, by: 1) == .level1)
        #expect(HeatingLevel.stepping(from: .unspecified, by: -1) == .unspecified)
    }

    @Test
    func activeMeansARealLevelIsSet() {
        #expect(HeatingLevel.level1.isHeatingActive)
        #expect(HeatingLevel.level2.isHeatingActive)
        #expect(HeatingLevel.level3.isHeatingActive)
        #expect(!HeatingLevel.off.isHeatingActive)
        #expect(!HeatingLevel.unspecified.isHeatingActive)
    }
}
