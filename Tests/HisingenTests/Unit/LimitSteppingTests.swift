import Foundation
import Testing
@testable import Hisingen

struct LimitSteppingTests {
    @Test func aChargeTargetMovesByTheStepInPoints() {
        let range = 40...100
        #expect(LimitStepping.raised(80, within: range, step: .five) == 85)
        #expect(LimitStepping.raised(80, within: range, step: .ten) == 90)
    }

    @Test func aStepNeverPassesTheCeiling() {
        #expect(LimitStepping.raised(95, within: 40...100, step: .ten) == 100)
        #expect(LimitStepping.raised(30, within: 6...32, step: .ten) == 32)
    }

    @Test func nothingRaisesAtTheCeiling() {
        #expect(LimitStepping.raised(100, within: 40...100, step: .five) == nil)
        #expect(LimitStepping.raised(32, within: 6...32, step: .ten) == nil)
    }

    @Test func currentLimitStepsAreAShareOfTheCap() {
        #expect(LimitStepping.size(upperBound: 32, step: .five) == 2)
        #expect(LimitStepping.size(upperBound: 32, step: .ten) == 3)
        #expect(LimitStepping.raised(16, within: 6...32, step: .five) == 18)
        #expect(LimitStepping.raised(16, within: 6...32, step: .ten) == 19)
    }

    @Test func aLowCeilingStillMovesByOne() {
        #expect(LimitStepping.size(upperBound: 10, step: .five) == 1)
        #expect(LimitStepping.raised(6, within: 6...10, step: .five) == 7)
    }

    @Test func aReadingBelowTheRangeLandsInsideIt() {
        #expect(LimitStepping.raised(0, within: 6...32, step: .five) == 6)
    }

    @Test func repeatedPressesClimbToTheCeilingAndStop() {
        var value = 6
        var presses = 0
        while let next = LimitStepping.raised(value, within: 6...32, step: .ten) {
            value = next
            presses += 1
        }
        #expect(value == 32)
        #expect(presses == 9)
    }

    @Test func pastTheCeilingALimitRestartsAtFortyPercentOfIt() {
        #expect(LimitStepping.restartValue(within: 6...32) == 13)
        #expect(LimitStepping.restartValue(within: 40...100) == 40)
        #expect(LimitStepping.pressed(32, within: 6...32, step: .five) == (13, true))
        #expect(LimitStepping.pressed(100, within: 40...100, step: .ten) == (40, true))
    }

    @Test func theRestartNeverLeavesTheRange() {
        #expect(LimitStepping.restartValue(within: 6...10) == 6)
        #expect(LimitStepping.restartValue(within: 50...100) == 50)
        #expect(LimitStepping.restartValue(within: 6...6) == 6)
    }

    @Test func belowTheCeilingAPressStillRaises() {
        #expect(LimitStepping.pressed(16, within: 6...32, step: .five) == (18, false))
    }

    @Test func aFullCycleClimbsThenRestartsThenClimbsAgain() {
        var value = 13
        var restarts = 0
        for _ in 0..<12 {
            let press = LimitStepping.pressed(value, within: 6...32, step: .ten)
            if press.restarts { restarts += 1 }
            value = press.value
        }
        #expect(restarts == 1)
        #expect((6...32).contains(value))
    }

    @Test func aTypedValueMustBeAWholeNumberInsideTheRange() {
        #expect(LimitStepping.entry("16", within: 6...32) == 16)
        #expect(LimitStepping.entry(" 20 ", within: 6...32) == 20)
        #expect(LimitStepping.entry("5", within: 6...32) == nil)
        #expect(LimitStepping.entry("33", within: 6...32) == nil)
        #expect(LimitStepping.entry("", within: 6...32) == nil)
        #expect(LimitStepping.entry("1.5", within: 6...32) == nil)
        #expect(LimitStepping.entry("-8", within: 6...32) == nil)
        #expect(LimitStepping.entry("٢٠", within: 6...32) == nil)
    }

    @Test func theStepIsStoredAndDefaultsToFivePercent() throws {
        let suite = "HisingenLimitStepTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LimitStep(rawValue: defaults.integer(forKey: "now_limit_step")) == nil)
        defaults.set(LimitStep.ten.rawValue, forKey: "now_limit_step")
        #expect(LimitStep(rawValue: defaults.integer(forKey: "now_limit_step")) == .ten)
    }
}

struct ClimateCountdownTests {
    private let reportedAt = Date(timeIntervalSince1970: 1_000_000)

    private func left(_ minutes: Int, after seconds: TimeInterval) -> Int? {
        ClimateCountdown.minutesRemaining(reported: minutes, at: reportedAt, now: reportedAt.addingTimeInterval(seconds))
    }

    @Test func showsTheReportedFigureAtTheMomentOfTheReport() {
        #expect(left(18, after: 0) == 18)
    }

    @Test func dropsByOneAMinuteAfterTheReport() {
        #expect(left(18, after: 59) == 18)
        #expect(left(18, after: 60) == 17)
        #expect(left(18, after: 61) == 17)
        #expect(left(18, after: 600) == 8)
    }

    @Test func endsAtZeroInsteadOfShowingZero() {
        #expect(left(2, after: 119) == 1)
        #expect(left(2, after: 120) == nil)
        #expect(left(2, after: 900) == nil)
    }

    @Test func saysNothingWhenTheCarGaveNoTime() {
        #expect(left(0, after: 0) == nil)
    }

    @Test func aReportFromTheFutureDoesNotAddTime() {
        #expect(left(18, after: -120) == 18)
    }
}
