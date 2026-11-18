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
    static let tibberHomeKey = "home_charging_tibber_home_v1"
    static let tibberNetworkFeeKey = "home_charging_tibber_network_fee_v1"
    static let gridTariffKey = "home_charging_grid_tariff_v1"
    static let tibberVendor = "tibber"
    private static let nexBlueImportKey = "home_charging_nexblue_import_v1"

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

    var nexBlueImport: HomeSessionSync.ImportReceipt? {
        get {
            guard let data = defaults.data(forKey: Self.nexBlueImportKey) else { return nil }
            return try? JSONDecoder.iso.decode(HomeSessionSync.ImportReceipt.self, from: data)
        }
        nonmutating set {
            defaults.set(newValue.flatMap { try? JSONEncoder.sortedISO.encode($0) }, forKey: Self.nexBlueImportKey)
        }
    }

    var hasToken: Bool { keychain.hasStoredHomeAssistantToken }

    func token() throws -> String? { try keychain.readHomeAssistantToken() }
    func saveToken(_ token: String) throws { try keychain.saveHomeAssistantToken(token) }

    // MARK: Electricity supplier (Tibber)

    /// The Tibber home that prices charger sessions. The token is in the Keychain; this is not secret.
    var tibberHome: TibberHome? {
        get {
            guard let data = defaults.data(forKey: Self.tibberHomeKey) else { return nil }
            return try? JSONDecoder().decode(TibberHome.self, from: data)
        }
        nonmutating set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.tibberHomeKey)
                return
            }
            defaults.set(data, forKey: Self.tibberHomeKey)
        }
    }

    /// The reader's variable network fee in öre per kWh, which Tibber's all-in price leaves out. It is
    /// not secret and belongs to the supplier, so the planner can use it with no charger paired.
    var tibberNetworkFeeOrePerKwh: Double {
        get { max(0, defaults.double(forKey: Self.tibberNetworkFeeKey)) }
        nonmutating set { defaults.set(max(0, newValue), forKey: Self.tibberNetworkFeeKey) }
    }

    /// The reader's grid tariff. Not secret, and kept when Tibber is disconnected so reconnecting does
    /// not mean typing it again. `nil` until one is saved; the older flat fee is read as a flat tariff.
    var gridTariff: GridTariff? {
        get {
            guard let data = defaults.data(forKey: Self.gridTariffKey) else { return nil }
            return try? JSONDecoder().decode(GridTariff.self, from: data)
        }
        nonmutating set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: Self.gridTariffKey)
                return
            }
            defaults.set(data, forKey: Self.gridTariffKey)
        }
    }

    var hasTibberToken: Bool { keychain.hasStoredChargerCredentials(vendor: Self.tibberVendor) }
    func tibberToken() throws -> String? { try keychain.readChargerCredentials(vendor: Self.tibberVendor) }
    func saveTibberToken(_ token: String) throws { try keychain.saveChargerCredentials(token, vendor: Self.tibberVendor) }

    func clearTibber() {
        defaults.removeObject(forKey: Self.tibberHomeKey)
        defaults.removeObject(forKey: Self.tibberNetworkFeeKey)
        try? keychain.deleteChargerCredentials(vendor: Self.tibberVendor)
    }

    // MARK: Direct chargers

    func hasCredentials(for source: ChargerSource) -> Bool {
        source.isDirect && keychain.hasStoredChargerCredentials(vendor: source.rawValue)
    }

    func credentials(for source: ChargerSource) throws -> DirectChargerCredentials? {
        guard source.isDirect, source != .nexBlue, let json = try keychain.readChargerCredentials(vendor: source.rawValue),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DirectChargerCredentials.self, from: data)
    }

    func saveCredentials(_ credentials: DirectChargerCredentials, for source: ChargerSource) throws {
        guard source.isDirect, source != .nexBlue else { return }
        let data = try JSONEncoder().encode(credentials)
        try keychain.saveChargerCredentials(String(decoding: data, as: UTF8.self), vendor: source.rawValue)
    }

    func nexBlueRefreshToken() throws -> String? {
        try keychain.readChargerCredentials(vendor: ChargerSource.nexBlue.rawValue)
    }

    func saveNexBlueRefreshToken(_ token: String) throws {
        try keychain.saveChargerCredentials(token, vendor: ChargerSource.nexBlue.rawValue)
    }

    func updateNexBlueRefreshToken(_ rotatedToken: String?, previous: String) throws {
        guard try nexBlueRefreshToken() == previous else { throw DirectChargerError.unauthorized }
        if let rotatedToken, rotatedToken != previous { try saveNexBlueRefreshToken(rotatedToken) }
    }

    func deleteCredentials(for source: ChargerSource) {
        guard source.isDirect else { return }
        try? keychain.deleteChargerCredentials(vendor: source.rawValue)
    }

    /// Removes the pairing and the plan record but keeps address and token, so the reader can pair again.
    func clearPairing() {
        defaults.removeObject(forKey: Self.pairingKey)
        defaults.removeObject(forKey: Self.planRecordKey)
        defaults.removeObject(forKey: Self.nexBlueImportKey)
    }

    /// Everything Home Charging holds, token included.
    func eraseAll() {
        clearPairing()
        defaults.removeObject(forKey: Self.addressKey)
        defaults.removeObject(forKey: Self.capturePresenceKey)
        try? keychain.deleteHomeAssistantToken()
        for source in ChargerSource.allCases where source.isDirect { deleteCredentials(for: source) }
        clearTibber()
        defaults.removeObject(forKey: Self.gridTariffKey)
        HouseMeterStore(defaults: defaults, keychain: keychain).eraseAll()
    }
}
