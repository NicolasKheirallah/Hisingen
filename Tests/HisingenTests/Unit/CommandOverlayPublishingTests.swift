import Foundation
import Testing
@testable import Hisingen

/// The overlay's one writer. These cases used to be nine assignments spread across the refresh and
/// command modules; they are now the interface of the single module that owns `commandState`, so
/// the behaviours each call site relied on are asserted here instead of at each site.
@MainActor
struct CommandOverlayPublishingTests {
    @Test
    func publishingReceiptsKeepsALockItWasNotGiven() {
        var state = vehicle(vin: "VIN")
        state.claimOptimisticLock(until: .distantFuture)

        state.publish(CommandPresentationState(receipts: [receipt()]))

        #expect(state.commandState.receipts.count == 1)
        #expect(
            state.commandState.optimisticLockUntil == .distantFuture,
            "publishing the ledger's receipts must not drop a lock another command claimed")
    }

    @Test
    func publishingAnOverlayThatNamesALockReplacesBothFields() {
        var state = vehicle(vin: "VIN")

        state.publish(
            CommandPresentationState(optimisticLockUntil: .distantFuture, receipts: [receipt()]))

        #expect(state.commandState.receipts.count == 1)
        #expect(state.commandState.optimisticLockUntil == .distantFuture)
    }

    @Test
    func endingTheLockKeepsTheReceiptsOnScreen() {
        var state = vehicle(vin: "VIN")
        state.publish(
            CommandPresentationState(optimisticLockUntil: .distantFuture, receipts: [receipt()]))

        state.setOptimisticLock(nil)

        #expect(state.commandState.receipts.count == 1)
        #expect(state.commandState.optimisticLockUntil == nil)
    }

    @Test
    func claimingTheDisplayStartsTheLockAndWaitsForTheLedgersReceipts() {
        var state = vehicle(vin: "VIN")
        state.publish(CommandPresentationState(receipts: [receipt()]))

        state.claimOptimisticLock(until: .distantFuture)

        #expect(state.commandState.receipts.isEmpty, "the previous command's receipts leave the screen")
        #expect(state.commandState.optimisticLockUntil == .distantFuture)
    }

    @Test
    func anAwaitingCommandWithNoReceiptsPublishesNothing() {
        var state = vehicle(vin: "VIN")
        state.claimOptimisticLock(until: .distantFuture)

        state.publish(.empty)

        #expect(state.commandState.receipts.isEmpty)
        #expect(
            state.commandState.optimisticLockUntil == .distantFuture,
            "the lock survives a publish that has no receipts to show")
    }

    @Test
    func strippingLeavesNothingForAFreshReadToCarry() {
        var state = vehicle(vin: "VIN")
        state.publish(
            CommandPresentationState(optimisticLockUntil: .distantFuture, receipts: [receipt()]))

        state.stripPresentationState()

        #expect(state.commandState == .empty)
    }
}

private func receipt() -> CommandReceipt {
    CommandReceipt(commandIdentifier: "honk-horn", issuedAt: Date(), command: .honkHorn)
}
