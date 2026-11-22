import Foundation
import Testing
@testable import Hisingen

/// The Polestar ID path cannot read a charge override back, so the card may only say that
/// Hisingen *sent* one. These tests pin the window and the command filter that decide when.
struct ChargeOverrideEvidenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(_ command: RemoteCommand, at date: Date) -> CommandReceipt {
        CommandReceipt(commandIdentifier: command.identifier, issuedAt: date, command: command)
    }

    @Test
    func aRecentStartOverrideQualifies() {
        let start = receipt(.startChargingOverride, at: now.addingTimeInterval(-60))
        #expect(ChargeOverrideEvidence.hasRecentOverride([start], now: now))
    }

    @Test
    func aRecentStopOverrideAlsoQualifies() {
        let stop = receipt(.stopChargingOverride, at: now.addingTimeInterval(-60))
        #expect(ChargeOverrideEvidence.hasRecentOverride([stop], now: now))
    }

    @Test
    func anOlderOverrideDoesNot() {
        let old = receipt(.startChargingOverride,
                          at: now.addingTimeInterval(-ChargeOverrideEvidence.noteWindow - 1))
        #expect(!ChargeOverrideEvidence.hasRecentOverride([old], now: now))
    }

    @Test
    func anUnrelatedCommandDoesNot() {
        let lock = receipt(.lock, at: now.addingTimeInterval(-60))
        #expect(!ChargeOverrideEvidence.hasRecentOverride([lock], now: now))
    }

    @Test
    func aClockSkewedFutureReceiptDoesNot() {
        let future = receipt(.startChargingOverride, at: now.addingTimeInterval(60))
        #expect(!ChargeOverrideEvidence.hasRecentOverride([future], now: now))
    }
}
