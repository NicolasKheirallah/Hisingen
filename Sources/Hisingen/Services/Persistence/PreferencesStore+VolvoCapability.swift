import Foundation

/// Durable record of the Volvo authorization's scope request and grant.
///
/// Kept outside `PreferencesStore+Account` on purpose: it is diagnostics state about one
/// provider's OAuth grant, not account configuration, and it must survive relaunches so the
/// capability inspector can distinguish "Volvo granted this" from "Hisingen asked and never
/// heard back" without waiting for the next token refresh.
extension PreferencesStore {
    private enum VolvoScopeKeys {
        static let requested = "volvo_requested_scopes_v1"
        static let granted = "volvo_granted_scopes"
        static let tier = "volvo_grant_tier_v1"
        static let recordedAt = "volvo_scope_grant_recorded_at_v1"
    }

    /// The widest scope set the last sign-in asked for, in the order it was sent.
    var volvoRequestedScopes: [String] {
        d.stringArray(forKey: VolvoScopeKeys.requested) ?? []
    }

    /// The scopes the token response said it granted. Empty means no grant has been recorded
    /// (or the session predates the recording), which consumers treat as unknown rather than
    /// as "granted nothing".
    var volvoGrantedScopes: [String] {
        get { d.stringArray(forKey: VolvoScopeKeys.granted) ?? [] }
        set { d.set(newValue, forKey: VolvoScopeKeys.granted) }
    }

    /// The requested tier's raw value: 0 full, 1 standard, 2 core.
    var volvoGrantTier: Int? {
        d.object(forKey: VolvoScopeKeys.tier) as? Int
    }

    var volvoScopeGrantRecordedAt: Date? {
        d.object(forKey: VolvoScopeKeys.recordedAt) as? Date
    }

    func recordVolvoScopeRequest(_ scopes: [String], tier: Int) {
        d.set(scopes, forKey: VolvoScopeKeys.requested)
        d.set(tier, forKey: VolvoScopeKeys.tier)
    }

    /// Records what the token response granted. A grant without a `scope` member keeps the
    /// previous list: the authorization did not contradict it, it simply did not repeat it.
    func recordVolvoGrantedScopes(_ scopes: [String]?, at date: Date) {
        if let scopes {
            volvoGrantedScopes = scopes
        }
        d.set(date, forKey: VolvoScopeKeys.recordedAt)
    }

    func clearVolvoScopeGrant() {
        d.removeObject(forKey: VolvoScopeKeys.requested)
        volvoGrantedScopes = []
        d.removeObject(forKey: VolvoScopeKeys.tier)
        d.removeObject(forKey: VolvoScopeKeys.recordedAt)
    }
}
