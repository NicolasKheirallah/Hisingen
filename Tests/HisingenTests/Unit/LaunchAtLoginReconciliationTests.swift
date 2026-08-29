import ServiceManagement
import Testing
@testable import Hisingen

/// The login-item reconcile. The bug this locks down: an app update / replace
/// invalidates the `SMAppService` registration (`status` becomes `.notFound`), and
/// the old code read that as "user turned it off" and cleared
/// `preferences.launchAtLogin`. The reconcile must instead re-register and never
/// touch the stored intent.
@Suite
struct LaunchAtLoginReconciliationTests {

    private func resolve(
        intent: Bool,
        status: SMAppService.Status,
        userInitiated: Bool = false
    ) -> LaunchAtLoginReconciliation {
        LaunchAtLoginReconciliation.resolve(intent: intent, status: status, userInitiated: userInitiated)
    }

    // MARK: - The regression

    @Test
    func staleRegistrationAfterAnUpdateReRegistersInsteadOfForgetting() {
        // First launch of a freshly replaced/updated bundle: the old registration
        // no longer matches this bundle's signature.
        XCTAssertEqual(resolve(intent: true, status: .notFound), .register)
        // And it does NOT depend on the launch being user-initiated — this fires on
        // the automatic startup reconcile.
        XCTAssertEqual(resolve(intent: true, status: .notFound, userInitiated: false), .register)
    }

    @Test
    func aWronglyClearedIntentIsRecoveredOnlyOnTheStartupReconcile() {
        // Automatic startup: registration survived the update but a previous build
        // had already wiped the preference — restore it.
        XCTAssertEqual(resolve(intent: false, status: .enabled, userInitiated: false), .restoreClearedIntent)
        // User just toggled it off: that must win, not be reverted.
        XCTAssertEqual(resolve(intent: false, status: .enabled, userInitiated: true), .unregister)
    }

    // MARK: - Normal reconcile

    @Test
    func intentOnRegistersWhenNotYetRegistered() {
        XCTAssertEqual(resolve(intent: true, status: .notRegistered), .register)
    }

    @Test
    func intentOnWithLiveRegistrationIsANoOp() {
        XCTAssertEqual(resolve(intent: true, status: .enabled), .none)
    }

    @Test
    func approvalIsOnlyChasedWhenTheUserJustAskedForIt() {
        // Automatic startup reconcile: don't yank the user into System Settings.
        XCTAssertEqual(resolve(intent: true, status: .requiresApproval, userInitiated: false), .none)
        // They just flipped the switch: sending them to approve is expected.
        XCTAssertEqual(resolve(intent: true, status: .requiresApproval, userInitiated: true), .promptForApproval)
    }

    @Test
    func intentOffUnregistersAnActiveOrPendingLoginItem() {
        XCTAssertEqual(resolve(intent: false, status: .requiresApproval), .unregister)
    }

    @Test
    func intentOffWithNothingRegisteredIsANoOp() {
        // The common case for a user who never enabled it — must not thrash.
        XCTAssertEqual(resolve(intent: false, status: .notRegistered), .none)
        XCTAssertEqual(resolve(intent: false, status: .notFound), .none)
    }

    // MARK: - No path clears the stored intent

    @Test
    func noOutcomeEverAsksToDisableTheStoredIntent() {
        let states: [SMAppService.Status] = [.notRegistered, .enabled, .requiresApproval, .notFound]
        for intent in [true, false] {
            for status in states {
                for userInitiated in [true, false] {
                    let action = resolve(intent: intent, status: status, userInitiated: userInitiated)
                    // `.restoreClearedIntent` turns the preference back ON; nothing
                    // turns it off. Disabling only ever comes from the user toggle.
                    XCTAssertTrue(
                        action != .restoreClearedIntent || intent == false,
                        "restore should only apply when the stored intent was off"
                    )
                }
            }
        }
    }
}
