import Foundation

/// Durable provider backoff: how long a provider has stood down from one endpoint or secondary
/// source, and why.
///
/// One owner, because both adapters grew the same idea separately – Volvo a dictionary of epoch
/// seconds under `volvo_endpoint_backoff_v1`, Polestar a timestamp plus a reason string under two
/// more keys – all of them in `UserDefaults.standard`, outside the erasure regime and unreachable
/// from a test that did not want to touch the real defaults domain.
///
/// A value type holding the database handle: it keeps no state of its own to serialize, and the
/// handle's lock is what makes it safe to call from either provider actor.
struct ProviderBackoffStore: Sendable {
    /// Identifies one stand-down. Its owner names the identifier, so this shared store never learns
    /// which brand or endpoint is behind it. The vehicle is part of the subject for the per-vehicle
    /// stand-downs and absent for the provider-wide ones, which is also what decides which erase
    /// scopes reach them.
    struct Subject: Hashable, Sendable {
        let identifier: String
        let vin: String?

        init(_ identifier: String, vin: String? = nil) {
            self.identifier = identifier
            self.vin = vin
        }
    }

    private let database: VehicleDatabase

    init(database: VehicleDatabase = .shared) {
        self.database = database
    }

    /// The row key. A vehicle-scoped subject namespaces the vehicle into the key because the table
    /// is keyed by subject alone (`subject TEXT PRIMARY KEY`): two cars sharing
    /// `volvo.endpoint.environment` would otherwise share one stand-down, so a market restriction
    /// learned for one VIN would skip a probe that had never failed on another. `vin` stays a
    /// column so the erase scopes can still select vehicle-scoped rows.
    private func storageKey(for subject: Subject) -> String {
        guard let vin = subject.vin, !vin.isEmpty else { return subject.identifier }
        return "\(subject.identifier)|\(vin)"
    }

    /// The date `subject` may be probed again, or nil when it is not standing down. Expired
    /// stand-downs answer nil without being deleted: reading stays pure, and the launch pass
    /// drops the closed rows.
    func blockedUntil(_ subject: Subject, now: Date = Date()) -> Date? {
        guard let entry = database.providerBackoff(for: storageKey(for: subject)),
              entry.blockedUntil > now else { return nil }
        return entry.blockedUntil
    }

    /// Why a subject stood down, for the diagnostics export. `fallback` is what the export reports
    /// when the reason was not recorded.
    func reason(for subject: Subject, fallback: String) -> String {
        database.providerBackoff(for: storageKey(for: subject))?.reason ?? fallback
    }

    func block(_ subject: Subject, until: Date, reason: String?) {
        database.saveProviderBackoff(
            subject: storageKey(for: subject), vin: subject.vin, blockedUntil: until, reason: reason)
    }

    func unblock(_ subject: Subject) {
        database.deleteProviderBackoff(subject: storageKey(for: subject))
    }
}
