import Foundation

/// Where Home Charging keeps what the reader configured. The access token lives in the Keychain
/// alone; everything else is non-secret and stays out of the settings archive because none of
/// these keys is on its transferable list.
@MainActor
struct HomeChargingStore {
    static let addressKey = "home_charging_address_v1"
    /// The pairing saved before a second charger was possible. Still written as a mirror of the
    /// first pairing so an older build can read this install; the list below is authoritative.
    static let pairingKey = "home_charging_pairing_v1"
    static let pairingsKey = "home_charging_pairings_v1"
    static let planRecordKey = "home_charging_plan_record_v1"
    static let planRecordsKey = "home_charging_plan_records_v1"
    static let capturePresenceKey = "home_charging_capture_seen_v1"
    static let tibberHomeKey = "home_charging_tibber_home_v1"
    static let tibberNetworkFeeKey = "home_charging_tibber_network_fee_v1"
    static let gridTariffKey = "home_charging_grid_tariff_v1"
    static let tibberVendor = "tibber"
    private static let nexBlueImportKey = "home_charging_nexblue_import_v1"
    private static let nexBlueRepriceKey = "home_charging_nexblue_reprice_v1"

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

    /// Every pairing this install holds, in the order they were added. A list saved by this build
    /// wins; an install that only has the pre-second-charger value reads as a list of one, which is
    /// the upgrade path. Writing the list also mirrors its first entry into the legacy key, so a
    /// downgrade still finds a charger and an erase leaves nothing behind.
    var pairings: [HomeChargingPairing] {
        get {
            if let data = defaults.data(forKey: Self.pairingsKey),
               let decoded = try? JSONDecoder.iso.decode([HomeChargingPairing].self, from: data) {
                return decoded
            }
            guard let data = defaults.data(forKey: Self.pairingKey),
                  let legacy = try? JSONDecoder.iso.decode(HomeChargingPairing.self, from: data) else {
                return []
            }
            return [legacy]
        }
        nonmutating set {
            var seen = Set<String>()
            let unique = newValue.filter { seen.insert($0.identity).inserted }
            guard let data = try? JSONEncoder.sortedISO.encode(unique) else {
                defaults.removeObject(forKey: Self.pairingsKey)
                return
            }
            defaults.set(data, forKey: Self.pairingsKey)
            if let first = unique.first, let legacy = try? JSONEncoder.sortedISO.encode(first) {
                defaults.set(legacy, forKey: Self.pairingKey)
            } else {
                defaults.removeObject(forKey: Self.pairingKey)
            }
        }
    }

    /// The legacy single-pairing accessor. Reads the first pairing; writing replaces the whole list,
    /// which is only what an unpair-everything or a test does.
    var pairing: HomeChargingPairing? {
        get { pairings.first }
        nonmutating set {
            if let newValue { pairings = [newValue] } else { pairings = [] }
        }
    }

    func pairing(identity: String) -> HomeChargingPairing? {
        pairings.first { $0.identity == identity }
    }

    /// Adds a charger, or replaces the pairing for the identical charger and vehicle.
    nonmutating func upsert(_ pairing: HomeChargingPairing) {
        var all = pairings
        if let index = all.firstIndex(where: { $0.identity == pairing.identity }) {
            all[index] = pairing
        } else {
            all.append(pairing)
        }
        pairings = all
    }

    /// Removes one charger and the plan record that belonged to it, keeping every other pairing.
    nonmutating func removePairing(identity: String) {
        guard let existing = pairing(identity: identity) else { return }
        pairings = pairings.filter { $0.identity != identity }
        setPlanRecord(nil, for: existing)
        if let receipt = nexBlueImport, receipt.chargerID == existing.chargerID {
            // The import receipt belongs to the charger that produced it; forgetting that charger
            // must not make the next import skip sessions it already recorded for another one.
            defaults.removeObject(forKey: Self.nexBlueImportKey)
            defaults.removeObject(forKey: Self.nexBlueRepriceKey)
        }
    }

    /// The plan record of the first pairing, for call sites that predate a second charger.
    var planRecord: HomeChargingPlanRecord? {
        get {
            guard let first = pairings.first else {
                return legacyPlanRecord
            }
            return planRecord(for: first)
        }
        nonmutating set {
            guard let first = pairings.first else {
                defaults.set(newValue.flatMap { try? JSONEncoder.sortedISO.encode($0) },
                             forKey: Self.planRecordKey)
                return
            }
            setPlanRecord(newValue, for: first)
        }
    }

    /// The plan record one charger is running. Keyed by the record's own charger and VIN so the
    /// two chargers never read each other's plan; an install that only has the legacy single record
    /// hands it to whichever pairing it belongs to.
    func planRecord(for pairing: HomeChargingPairing) -> HomeChargingPlanRecord? {
        if let data = defaults.data(forKey: Self.planRecordsKey),
           let decoded = try? JSONDecoder.iso.decode([String: HomeChargingPlanRecord].self, from: data),
           let record = decoded[pairing.identity] {
            return record
        }
        if let legacy = legacyPlanRecord,
           legacy.chargerID == pairing.chargerID,
           legacy.vin.caseInsensitiveCompare(pairing.vin) == .orderedSame {
            return legacy
        }
        return nil
    }

    nonmutating func setPlanRecord(_ record: HomeChargingPlanRecord?, for pairing: HomeChargingPairing) {
        var all = planRecords
        if let record {
            all[pairing.identity] = record
        } else {
            all.removeValue(forKey: pairing.identity)
        }
        planRecords = all
    }

    private var planRecords: [String: HomeChargingPlanRecord] {
        get {
            guard let data = defaults.data(forKey: Self.planRecordsKey),
                  let decoded = try? JSONDecoder.iso.decode([String: HomeChargingPlanRecord].self, from: data) else {
                return [:]
            }
            return decoded
        }
        nonmutating set {
            guard !newValue.isEmpty, let data = try? JSONEncoder.sortedISO.encode(newValue) else {
                defaults.removeObject(forKey: Self.planRecordsKey)
                return
            }
            defaults.set(data, forKey: Self.planRecordsKey)
        }
    }

    /// The single plan record saved before per-charger records existed.
    private var legacyPlanRecord: HomeChargingPlanRecord? {
        guard let data = defaults.data(forKey: Self.planRecordKey) else { return nil }
        return try? JSONDecoder.iso.decode(HomeChargingPlanRecord.self, from: data)
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

    /// Set once the sessions imported before hourly energy was read have been priced again.
    var nexBlueRepriced: Bool {
        get { defaults.bool(forKey: Self.nexBlueRepriceKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.nexBlueRepriceKey) }
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

    /// Removes every pairing and plan record but keeps address and token, so the reader can pair again.
    func clearPairing() {
        defaults.removeObject(forKey: Self.pairingKey)
        defaults.removeObject(forKey: Self.pairingsKey)
        defaults.removeObject(forKey: Self.planRecordKey)
        defaults.removeObject(forKey: Self.planRecordsKey)
        defaults.removeObject(forKey: Self.nexBlueImportKey)
        defaults.removeObject(forKey: Self.nexBlueRepriceKey)
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
