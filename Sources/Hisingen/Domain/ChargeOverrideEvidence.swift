import Foundation

/// What Hisingen can honestly say about a charge-schedule override when the provider cannot read
/// its current state.
///
/// The Polestar ID path has a write for "charge now" and no verified read, so
/// `energy.chargeNowActive` stays `nil` there and the pill never lights up. A receipt proves only
/// that Hisingen *sent* the command; it never proves the car is still in the override, because the
/// car can end it on its own. This type therefore answers "did the reader just do this?", which is
/// a fact, and leaves the state question to the copy.
enum ChargeOverrideEvidence {
    /// How long a sent override stays worth a note. Long enough to explain the button the reader
    /// pressed this evening; short enough that it never reads as live state tomorrow.
    static let noteWindow: TimeInterval = 12 * 60 * 60

    /// True when a start or stop of the schedule override was sent inside the note window.
    static func hasRecentOverride(_ receipts: [CommandReceipt], now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-noteWindow)
        return receipts.contains { receipt in
            guard receipt.issuedAt >= cutoff, receipt.issuedAt <= now else { return false }
            switch receipt.command {
            case .startChargingOverride, .stopChargingOverride:
                return true
            default:
                return false
            }
        }
    }
}
