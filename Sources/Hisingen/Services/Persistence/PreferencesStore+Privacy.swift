import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    /// Screenshot privacy mode: when on, views marked `.privacySensitive()` (VIN, plate,
    /// coordinates) render as placeholders under SwiftUI's privacy redaction.
    var privacyRedactionEnabled: Bool {
        get { d.bool(forKey: "privacy_redaction_enabled") }
        set { d.set(newValue, forKey: "privacy_redaction_enabled") }
    }

    /// A VIN as it may be shown: redacted to its last four characters when screenshot privacy is on.
    ///
    /// The Privacy card promises that turning this on blurs "VIN, plate and coordinates across the
    /// app", and every surface that shows a VIN has to give the same answer. Four of them spelled
    /// the same expression by hand and one of them — the capability matrix, which is the card most
    /// likely to be screenshotted and exported — did not redact at all.
    func displayVIN(_ vin: String) -> String {
        privacyRedactionEnabled ? "VIN •••·\(vin.suffix(4))" : "VIN: \(vin)"
    }

    /// Whether an export filename may carry the VIN. A redacted screenshot still leaves the file
    /// sitting in a shared folder under the reader's own name.
    func exportVINComponent(_ vin: String) -> String {
        privacyRedactionEnabled ? "shared" : String(vin.prefix(8))
    }

    var persistLocationHistory: Bool { get { d.bool(forKey: "persist_location_history") } set { d.set(newValue, forKey: "persist_location_history") } }

    var historySampleRetentionDays: Int { get { let value = d.integer(forKey: "history_sample_retention_days"); return [30, 90, 180, 365].contains(value) ? value : 90 } set { d.set([30, 90, 180, 365].contains(newValue) ? newValue : 90, forKey: "history_sample_retention_days") } }
    /// When enabled, signing out – or switching to a different account – also erases the
    /// local SQLite history (charging sessions, telemetry, battery health, fuel entries…)
    /// for the affected vehicles. Off by default: a re-signed local build, a Keychain
    /// prompt dismissed by accident, or a stray sign-out should not discard months of
    /// history. The explicit "Erase local vehicle data" action in Settings → Privacy &
    /// Data is the deliberate way to remove it.
    var eraseHistoryOnSignOut: Bool { get { d.bool(forKey: "erase_history_on_sign_out") } set { d.set(newValue, forKey: "erase_history_on_sign_out") } }

    var storeChargingHistory: Bool { get { d.bool(forKey: "store_charging_history") } set { d.set(newValue, forKey: "store_charging_history") } }

    var privateNotificationDetails: Bool { get { d.object(forKey: "private_notification_details") == nil || d.bool(forKey: "private_notification_details") } set { d.set(newValue, forKey: "private_notification_details") } }
    var requireBiometricsForRemoteControls: Bool { get { d.bool(forKey: "require_biometrics_for_remote_controls") } set { d.set(newValue, forKey: "require_biometrics_for_remote_controls") } }
}
