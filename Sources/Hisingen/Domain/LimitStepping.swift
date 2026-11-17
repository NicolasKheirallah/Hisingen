import Foundation

/// How far one press on a limit card raises its limit, as a share of the highest value the car
/// allows. Five or ten percent of a 100 % charge target is five or ten points; of a 32 A cap it is
/// two or three amps. The reader picks one in Settings.
enum LimitStep: Int, CaseIterable, Sendable {
    case five = 5
    case ten = 10

    var title: String { Format.percent(Double(rawValue)) }
}

enum LimitStepping {
    /// One press, in the limit's own unit. Never less than one, so a low ceiling still moves.
    static func size(upperBound: Int, step: LimitStep) -> Int {
        max(1, Int((Double(upperBound) * Double(step.rawValue) / 100).rounded()))
    }

    /// The limit after one press, or `nil` when it is already at the ceiling and there is
    /// nothing left to raise. The result never leaves `range`.
    static func raised(_ current: Int, within range: ClosedRange<Int>, step: LimitStep) -> Int? {
        guard current < range.upperBound else { return nil }
        let next = current + size(upperBound: range.upperBound, step: step)
        return min(range.upperBound, max(range.lowerBound, next))
    }

    /// Where a limit starts over once it has reached its ceiling: 40 % of the highest value the car
    /// allows, never below the lowest. That is 13 A of a 32 A cap, and 40 % for a charge target,
    /// which is also where most cars set its floor.
    static func restartValue(within range: ClosedRange<Int>) -> Int {
        let share = Int((Double(range.upperBound) * 0.4).rounded())
        return min(range.upperBound, max(range.lowerBound, share))
    }

    /// One press: a step up, or the restart value when the limit is already at the ceiling. A card
    /// that only climbed would have no way back down.
    static func pressed(_ current: Int, within range: ClosedRange<Int>, step: LimitStep) -> (value: Int, restarts: Bool) {
        if let value = raised(current, within: range, step: step) { return (value, false) }
        return (restartValue(within: range), true)
    }

    /// A value the reader typed: a whole number inside `range`, otherwise `nil`.
    static func entry(_ text: String, within range: ClosedRange<Int>) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }), let value = Int(trimmed), range.contains(value) else {
            return nil
        }
        return value
    }
}

enum ClimateCountdown {
    /// Whole minutes left, counted down from the moment the car reported them. The car says
    /// "18 minutes" and nothing more, so the count rounds up and drops by one a minute after the
    /// report; it never shows seconds, which would claim a precision the car did not give.
    /// `nil` once it reaches zero or when the car reported no time, so the card says nothing
    /// until the next reading instead of "0 min".
    static func minutesRemaining(reported minutes: Int, at reportedAt: Date, now: Date) -> Int? {
        guard minutes > 0 else { return nil }
        let elapsed = max(0, now.timeIntervalSince(reportedAt))
        let left = Int(((Double(minutes) * 60 - elapsed) / 60).rounded(.up))
        return left > 0 ? left : nil
    }
}
