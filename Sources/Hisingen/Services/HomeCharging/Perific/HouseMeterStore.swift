import Foundation

/// Where the house meter keeps what the reader configured. The Perific login lives in the Keychain
/// alone, in one item with the other vendor logins; the chosen meter is not secret and stays out of
/// the settings archive because its key is not on the transferable list.
@MainActor
struct HouseMeterStore {
    static let meterKey = "house_meter_v1"
    static let vendor = "perific"

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    init(defaults: UserDefaults, keychain: KeychainStore) {
        self.defaults = defaults
        self.keychain = keychain
    }

    var meter: HouseMeter? {
        get {
            guard let data = defaults.data(forKey: Self.meterKey) else { return nil }
            return try? JSONDecoder().decode(HouseMeter.self, from: data)
        }
        nonmutating set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.meterKey)
                return
            }
            defaults.set(data, forKey: Self.meterKey)
        }
    }

    var hasCredentials: Bool { keychain.hasStoredChargerCredentials(vendor: Self.vendor) }

    func credentials() throws -> DirectChargerCredentials? {
        guard let json = try keychain.readChargerCredentials(vendor: Self.vendor),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DirectChargerCredentials.self, from: data)
    }

    func saveCredentials(_ credentials: DirectChargerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try keychain.saveChargerCredentials(String(decoding: data, as: UTF8.self), vendor: Self.vendor)
    }

    /// The meter and the login. Signing in again is all it takes to come back.
    func eraseAll() {
        defaults.removeObject(forKey: Self.meterKey)
        try? keychain.deleteChargerCredentials(vendor: Self.vendor)
    }
}
