import Foundation

extension PreferencesStore {
    /// Reader-set parking-style fees. A JSON list rather than a database table: the rules are
    /// settings, and changing one re-prices the sessions it applies to on the next read.
    static let chargingOverstayRulesKey = "electricity_overstay_rules_v1"

    var chargingOverstayRules: [ChargingOverstayRule] {
        get {
            guard let data = d.data(forKey: Self.chargingOverstayRulesKey),
                  let rules = try? JSONDecoder.iso.decode([ChargingOverstayRule].self, from: data) else {
                return []
            }
            return rules
        }
        set {
            guard let data = try? JSONEncoder.sortedISO.encode(newValue) else {
                d.removeObject(forKey: Self.chargingOverstayRulesKey)
                return
            }
            d.set(data, forKey: Self.chargingOverstayRulesKey)
        }
    }

    func addChargingOverstayRule(_ rule: ChargingOverstayRule) {
        var rules = chargingOverstayRules.filter { $0.id != rule.id }
        rules.append(rule)
        chargingOverstayRules = rules
    }

    func removeChargingOverstayRule(id: String) {
        chargingOverstayRules = chargingOverstayRules.filter { $0.id != id }
    }

    /// Off by default: the alert needs a level the reader chooses, and a number they did not
    /// enter would be a guess about their bill.
    var notifyPriceThreshold: Bool {
        get { d.bool(forKey: "notify_price_threshold") }
        set { d.set(newValue, forKey: "notify_price_threshold") }
    }

    /// Keep the existing SEK setting when the reader connects or changes a Tibber home.
    var priceAlertThresholdSekPerKwh: Double {
        get { max(0, d.double(forKey: "notify_price_threshold_value")) }
        set { d.set(min(max(newValue, 0), 1_000), forKey: "notify_price_threshold_value") }
    }

    var priceAlertCurrency: String? {
        let supplier = HomeChargingStore(defaults: d, keychain: keychain)
        guard let home = supplier.tibberHome else { return "SEK" }
        return home.priceCurrency
    }

    func priceAlertThresholdPerKwh(currency: String) -> Double {
        if currency == "SEK" { return priceAlertThresholdSekPerKwh }
        let levels = d.dictionary(forKey: "notify_price_threshold_by_currency") as? [String: Double]
        return levels?[currency] ?? 0
    }

    func setPriceAlertThresholdPerKwh(_ value: Double, currency: String) {
        if currency == "SEK" {
            priceAlertThresholdSekPerKwh = value
            return
        }
        let key = "notify_price_threshold_by_currency"
        var levels = d.dictionary(forKey: key) as? [String: Double] ?? [:]
        levels[currency] = min(max(value, 0), 1_000)
        d.set(levels, forKey: key)
    }

    /// How long one price alert keeps the next one quiet. A quarter-hourly series can jump above
    /// and below a level several times in an hour, so this is what stops a volatile hour from
    /// filling the notification list.
    var priceAlertQuietMinutes: Int {
        get {
            let value = d.object(forKey: "notify_price_threshold_quiet_minutes") as? Int
            return min(max(value ?? 60, 15), 720)
        }
        set { d.set(min(max(newValue, 15), 720), forKey: "notify_price_threshold_quiet_minutes") }
    }

    /// The two stamps below are dedupe state, not preferences: their keys sit outside the
    /// transferable `notify_` prefix so exporting settings does not carry a quiet period to
    /// another Mac and silence its first alert.
    func priceAlertLastAlertedAt(for zone: ElspotZone) -> Date? {
        dictionaryDate(key: "price_alert_last_at_v1", zone: zone)
    }

    func setPriceAlertLastAlertedAt(_ date: Date?, for zone: ElspotZone) {
        setDictionaryDate(date, key: "price_alert_last_at_v1", zone: zone)
    }

    func priceAlertLastSlotStart(for zone: ElspotZone) -> Date? {
        dictionaryDate(key: "price_alert_last_slot_v1", zone: zone)
    }

    func setPriceAlertLastSlotStart(_ date: Date?, for zone: ElspotZone) {
        setDictionaryDate(date, key: "price_alert_last_slot_v1", zone: zone)
    }

    private func dictionaryDate(key: String, zone: ElspotZone) -> Date? {
        (d.dictionary(forKey: key) as? [String: Double])?[zone.rawValue]
            .map(Date.init(timeIntervalSince1970:))
    }

    private func setDictionaryDate(_ date: Date?, key: String, zone: ElspotZone) {
        var all = d.dictionary(forKey: key) as? [String: Double] ?? [:]
        if let date { all[zone.rawValue] = date.timeIntervalSince1970 } else { all.removeValue(forKey: zone.rawValue) }
        d.set(all, forKey: key)
    }
}
