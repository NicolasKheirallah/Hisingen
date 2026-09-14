import Foundation
import Testing
@testable import Hisingen

/// The admission precedence, asserted directly.
///
/// Every case here was previously re-derived inside an entry point, and the fact that the
/// orders legitimately differ per intent was written down nowhere. These tests are the record of
/// why they differ.
struct RefreshGateTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private let rateLimitedUntil: Date

    init() {
        rateLimitedUntil = Date(timeIntervalSince1970: 1_780_000_600)
    }

    @Test
    func anUnconstrainedGateStartsEveryIntent() {
        for intent in allIntents {
            #expect(RefreshGate.admit(intent, in: situation()) == .start, "\(intent)")
        }
    }

    @Test
    func aScheduledTickCoalescesWithInFlightWorkBeforeItAsksForASession() {
        // A tick that lands mid-fetch has nothing to add, so it must not report a missing
        // session and send the caller off to establish one.
        #expect(RefreshGate.admit(
            .scheduled, in: situation(hasSession: false, isWorking: true)) == .refused(.alreadyRunning))
    }

    @Test
    func aManualRefreshAsksForASessionBeforeItAsksAboutInFlightWork() {
        // Establishing the session defers on its own while work is running, so the session
        // question has to come first or the deferral never happens.
        #expect(RefreshGate.admit(
            .manual, in: situation(hasSession: false, isWorking: true)) == .refused(.needsSession))
    }

    @Test
    func onlyUserInitiatedIntentsRespectTheRateLimitWindow() {
        let limited = situation(rateLimitedUntil: rateLimitedUntil)

        // A scheduled tick's own delay already came from this window. Refusing it here would
        // mean re-arming the timer to avoid stopping the poll.
        #expect(RefreshGate.admit(.scheduled, in: limited) == .start)
        #expect(RefreshGate.admit(.wake, in: limited) == .start)
        #expect(RefreshGate.admit(.networkRestored, in: limited) == .start)

        #expect(RefreshGate.admit(.manual, in: limited) == .refused(.rateLimited(until: rateLimitedUntil)))
        #expect(RefreshGate.admit(.metadata, in: limited) == .refused(.rateLimited(until: rateLimitedUntil)))
        #expect(RefreshGate.admit(.selection(vin: "P1"), in: limited)
            == .refused(.rateLimited(until: rateLimitedUntil)))
    }

    @Test
    func anElapsedRateLimitWindowNoLongerRefuses() {
        let elapsed = situation(rateLimitedUntil: now)
        #expect(RefreshGate.admit(.manual, in: elapsed) == .start)
    }

    @Test
    func aSelectionSupersedesInFlightWorkWhileEveryOtherIntentCoalesces() {
        let busy = situation(isWorking: true)

        // A selection bumps the generation and cancels what is running.
        #expect(RefreshGate.admit(.selection(vin: "P2"), in: busy) == .start)
        #expect(RefreshGate.admit(.manual, in: busy) == .refused(.alreadyRunning))
        #expect(RefreshGate.admit(.metadata, in: busy) == .refused(.alreadyRunning))
        #expect(RefreshGate.admit(.scheduled, in: busy) == .refused(.alreadyRunning))
    }

    @Test
    func aSelectionIsRefusedByNothingButTheRateLimit() {
        // The switcher owns its own guards (already switching to this car, already settled);
        // a sleeping app, a dead network or an unestablished session are not its business.
        let hostile = situation(
            isAsleep: true, isOnline: false, hasSession: false, isWorking: true, selectedVIN: "")
        #expect(RefreshGate.admit(.selection(vin: "P1"), in: hostile) == .start)
    }

    @Test
    func anEmptySelectionIsRefusedOnlyAfterTheSessionCheck() {
        let noVehicle = situation(selectedVIN: "")
        #expect(RefreshGate.admit(.manual, in: noVehicle) == .refused(.noVehicleSelected))
        #expect(RefreshGate.admit(.scheduled, in: noVehicle) == .refused(.noVehicleSelected))

        // No session explains the empty selection, so it is the answer the caller needs.
        let noSession = situation(hasSession: false, selectedVIN: "")
        #expect(RefreshGate.admit(.manual, in: noSession) == .refused(.needsSession))
    }

    @Test
    func sleepOutranksInFlightWorkWhenEstablishingASession() {
        // The in-flight operation cannot outlive sleep, so sleep is the actionable answer.
        #expect(RefreshGate.admit(
            .establishSession, in: situation(isAsleep: true, isWorking: true)) == .refused(.asleep))
        // Work in flight outranks the network: the caller re-arms rather than reporting offline.
        #expect(RefreshGate.admit(
            .establishSession, in: situation(isOnline: false, isWorking: true)) == .refused(.alreadyRunning))
        #expect(RefreshGate.admit(
            .establishSession, in: situation(isOnline: false)) == .refused(.offline))
    }

    @Test
    func sleepIsRefusedBeforeTheNetwork() {
        #expect(RefreshGate.admit(
            .manual, in: situation(isAsleep: true, isOnline: false)) == .refused(.asleep))
    }

    // MARK: - Harness

    private var allIntents: [RefreshIntent] {
        [.scheduled, .manual, .wake, .networkRestored, .metadata, .selection(vin: "P1"), .establishSession]
    }

    private func situation(
        isAsleep: Bool = false,
        isOnline: Bool = true,
        hasSession: Bool = true,
        isWorking: Bool = false,
        rateLimitedUntil: Date? = nil,
        selectedVIN: String = "P1"
    ) -> RefreshGate.Situation {
        RefreshGate.Situation(
            isAsleep: isAsleep, isOnline: isOnline, hasSession: hasSession,
            isWorking: isWorking, rateLimitedUntil: rateLimitedUntil,
            selectedVIN: selectedVIN, now: now)
    }
}
