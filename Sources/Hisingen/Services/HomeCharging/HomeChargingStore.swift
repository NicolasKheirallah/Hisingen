import Foundation

/// Where Home Charging keeps what the reader configured. The access token lives in the Keychain
/// alone; everything else is non-secret and stays out of the settings archive because none of
/// these keys is on its transferable list.
@MainActor
struct HomeChargingStore {
    static let addressKey = "home_charging_address_v1"
    static let pairingKey = "home_charging_pairing_v1"
    static let planRecordKey = "home_charging_plan_record_v1"
    static let capturePresenceKey = "home_charging_capture_seen_v1"

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults, keychain: KeychainStore) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var address: String? {
        get { defaults.string(forKey: Self.addressKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.addressKey) }
    }

    var pairing: HomeChargingPairing? {
        get {
            guard let data = defaults.data(forKey: Self.pairingKey) else { return nil }
            return try? JSONDecoder.iso.decode(HomeChargingPairing.self, from: data)
        }
        nonmutating set {
            guard let newValue, let data = try? JSONEncoder.sortedISO.encode(newValue) else {
                defaults.removeObject(forKey: Self.pairingKey)
                return
            }
            defaults.set(data, forKey: Self.pairingKey)
        }
    }

    var planRecord: HomeChargingPlanRecord? {
        get {
            guard let data = defaults.data(forKey: Self.planRecordKey) else { return nil }
            return try? JSONDecoder.iso.decode(HomeChargingPlanRecord.self, from: data)
        }
        nonmutating set {
            guard let newValue, let data = try? JSONEncoder.sortedISO.encode(newValue) else {
                defaults.removeObject(forKey: Self.planRecordKey)
                return
            }
            defaults.set(data, forKey: Self.planRecordKey)
        }
    }

    /// Whether the durable capture component has answered before. The sync only asks for it once it has.
    var captureComponentSeen: Bool {
        get { defaults.bool(forKey: Self.capturePresenceKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.capturePresenceKey) }
    }

    var hasToken: Bool { keychain.hasStoredHomeAssistantToken }

    func token() throws -> String? { try keychain.readHomeAssistantToken() }
    func saveToken(_ token: String) throws { try keychain.saveHomeAssistantToken(token) }

    /// Removes the pairing and the plan record but keeps address and token, so the reader can pair again.
    func clearPairing() {
        defaults.removeObject(forKey: Self.pairingKey)
        defaults.removeObject(forKey: Self.planRecordKey)
    }

    /// Everything Home Charging holds, token included.
    func eraseAll() {
        clearPairing()
        defaults.removeObject(forKey: Self.addressKey)
        defaults.removeObject(forKey: Self.capturePresenceKey)
        try? keychain.deleteHomeAssistantToken()
    }
}
