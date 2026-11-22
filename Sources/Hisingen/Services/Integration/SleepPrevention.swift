import Foundation
import IOKit.pwr_mgt
import OSLog

/// The system-sleep assertion the Charging Planner holds while a cheap window is waiting
/// or running. A protocol so tests can drive the decision without touching power management.
@MainActor
protocol SleepPreventing: AnyObject {
    var isHolding: Bool { get }
    @discardableResult func hold(reason: String) -> Bool
    func release()
}

/// Keeps the Mac from going to idle sleep for as long as the assertion is held.
///
/// This is the only sleep-related power the app has: a normal Developer ID app cannot schedule
/// a wake (`IOPMSchedulePowerEvent` needs root and a privileged helper), so a Mac that is already
/// asleep cannot be woken to start a charge. The assertion covers the opposite case — the Mac is
/// awake when the plan is made and stays awake until the window ends, so the planner's minute
/// tick can send the start and stop commands.
@MainActor
final class SleepPrevention: SleepPreventing {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isHolding = false

    /// The reason is visible in `pmset -g assertions` and other power diagnostics. It is not
    /// app copy, so it stays in English.
    static let assertionReason = "Hisingen keeps this Mac awake for a charging window"

    @discardableResult
    func hold(reason: String = SleepPrevention.assertionReason) -> Bool {
        guard !isHolding else { return true }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            AppLog.logger("elpriser").error("Sleep prevention failed: \(result, privacy: .public)")
            return false
        }
        assertionID = id
        isHolding = true
        return true
    }

    func release() {
        guard isHolding else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHolding = false
    }
}
