import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    /// Preferred display order of the Charging card's detail rows. Identifiers not present
    /// keep their natural position after the ordered ones – so a partial list is safe.
    var chargingStatOrder: [String] {
        get {
            guard let raw = d.array(forKey: "charging_stat_order") as? [String] else { return [] }
            return raw
        }
        set { d.set(newValue, forKey: "charging_stat_order") }
    }

    /// Floating always-on-top panel while charging.
    var floatingChargingPanelEnabled: Bool {
        get { d.bool(forKey: "floating_charging_panel") }
        set { d.set(newValue, forKey: "floating_charging_panel") }
    }

    var electricityPricePerKwh: Double { get { let value = d.double(forKey: "electricity_price_per_kwh"); return value > 0 ? value : 2.0 } set { d.set(newValue, forKey: "electricity_price_per_kwh") } }
    var currencySymbol: String { get { let value = d.string(forKey: "electricity_currency_symbol") ?? ""; return value.isEmpty ? (Locale.current.currencySymbol ?? "kr") : value } set { d.set(newValue, forKey: "electricity_currency_symbol") } }
    /// Off-peak/night tariff, disabled by default so charging-cost estimates match
    /// `electricityPricePerKwh` unchanged unless the user opts in to a two-rate schedule.
    var nightTariffEnabled: Bool { get { d.bool(forKey: "night_tariff_enabled") } set { d.set(newValue, forKey: "night_tariff_enabled") } }
    var nightElectricityPricePerKwh: Double { get { let value = d.double(forKey: "night_electricity_price_per_kwh"); return value > 0 ? value : electricityPricePerKwh } set { d.set(newValue, forKey: "night_electricity_price_per_kwh") } }
    var nightTariffStartHour: Int { get { let value = d.object(forKey: "night_tariff_start_hour") as? Int; return min(max(value ?? 22, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "night_tariff_start_hour") } }
    var nightTariffEndHour: Int { get { let value = d.object(forKey: "night_tariff_end_hour") as? Int; return min(max(value ?? 6, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "night_tariff_end_hour") } }
    /// Swedish spot-price zone for the Charging Planner. Defaults to SE3, the most
    /// populous zone, so a first-run pick is one tap away rather than a wrong guess.
    var electricityPriceZone: ElspotZone {
        get { ElspotZone(rawValue: d.string(forKey: "electricity_price_zone") ?? "") ?? .se3 }
        set { d.set(newValue.rawValue, forKey: "electricity_price_zone") }
    }
    /// Country for electricity pricing. Unset installs infer it once: anyone already using the
    /// planner or automatic pricing is in Sweden by construction, otherwise the Mac's region
    /// decides. An explicit pick always wins and is never overwritten.
    var marketCountry: MarketCountry {
        get {
            if let stored = MarketCountry(rawValue: d.string(forKey: "electricity_market_country") ?? "") { return stored }
            if features.contains(.smartChargingPlanner) || d.string(forKey: "electricity_rate_mode") == ElectricityRateMode.automatic.rawValue {
                // Pinned the first time it is inferred, so turning the planner off later
                // cannot move an existing Swedish install to "Other country".
                d.set(MarketCountry.sweden.rawValue, forKey: "electricity_market_country")
                return .sweden
            }
            return Locale.current.region?.identifier == "SE" ? .sweden : .other
        }
        set { d.set(newValue.rawValue, forKey: "electricity_market_country") }
    }
    /// True when a Tibber home is connected. The home id is the non-secret marker; the token
    /// lives in the Keychain and `HomeChargingStore.clearTibber()` removes both together.
    var hasConnectedTibberHome: Bool {
        d.data(forKey: HomeChargingStore.tibberHomeKey) != nil
    }

    /// Whether any price series can be read at all. The selected supplier decides it: Tibber when
    /// the reader connected a home, otherwise the Swedish spot series. A supplier that publishes
    /// no series leaves this false, and the planner and price UI stay off rather than showing a
    /// number the app cannot source. This replaces the old "country is Sweden" question, which
    /// hid the planner from a Tibber home in Norway even though Tibber already returned its prices.
    var hasPriceSource: Bool {
        if electricityProvider == .tibber, hasConnectedTibberHome { return true }
        return marketCountry.offersMarketPricing
    }

    /// The planner needs a price series, so the feature switch alone is not enough.
    var smartChargingPlannerAvailable: Bool {
        hasPriceSource && features.contains(.smartChargingPlanner)
    }
    /// Fixed rate (the typed-in price per kWh) or automatic (spot price plus provider markup).
    /// Fixed by default so existing installs keep their figures until the user opts in.
    var electricityRateMode: ElectricityRateMode {
        get { ElectricityRateMode(rawValue: d.string(forKey: "electricity_rate_mode") ?? "") ?? .fixed }
        set { d.set(newValue.rawValue, forKey: "electricity_rate_mode") }
    }
    var electricityProvider: ElectricityProvider {
        get { ElectricityProvider(rawValue: d.string(forKey: "electricity_provider") ?? "") ?? .other }
        set { d.set(newValue.rawValue, forKey: "electricity_provider") }
    }
    /// 15-minute is the market's own granularity since 2025-10-01, so it is the default.
    var electricityPriceContract: ElectricityPriceContract {
        get { ElectricityPriceContract(rawValue: d.string(forKey: "electricity_price_contract") ?? "") ?? .quarterHour }
        set { d.set(newValue.rawValue, forKey: "electricity_price_contract") }
    }
    /// The provider's markup (påslag) over spot, in öre/kWh excluding VAT.
    var electricityMarkupOrePerKwh: Double {
        get { max(0, d.double(forKey: "electricity_markup_ore_per_kwh")) }
        set { d.set(min(max(newValue, 0), 1_000), forKey: "electricity_markup_ore_per_kwh") }
    }
    /// Energy tax, grid fee and anything else the user wants counted, in öre/kWh excluding VAT.
    var electricityOtherChargesOrePerKwh: Double {
        get { max(0, d.double(forKey: "electricity_other_charges_ore_per_kwh")) }
        set { d.set(min(max(newValue, 0), 1_000), forKey: "electricity_other_charges_ore_per_kwh") }
    }
    var electricityIncludesVAT: Bool { get { boolDefaultTrue("electricity_includes_vat") } set { d.set(newValue, forKey: "electricity_includes_vat") } }
    var electricityRatePolicy: ElectricityRatePolicy {
        ElectricityRatePolicy(
            mode: hasPriceSource ? electricityRateMode : .fixed, provider: electricityProvider, contract: electricityPriceContract,
            markupOrePerKwh: electricityMarkupOrePerKwh, otherChargesOrePerKwh: electricityOtherChargesOrePerKwh,
            includesVAT: electricityIncludesVAT
        )
    }
    /// Assumed charger output used to convert the energy still needed into whole
    /// charging hours when the vehicle is not reporting a live charging rate.
    var electricityChargerPowerKw: Double {
        get { let value = d.double(forKey: "electricity_charger_power_kw"); return value > 0 ? value : 7.4 }
        set { d.set(max(1, min(newValue, 250)), forKey: "electricity_charger_power_kw") }
    }

    /// The saved charge location the Charging Planner's solar forecast is drawn for. `nil` follows
    /// the car's reported position. The identifier is the backend's own, so a location that is
    /// later removed simply stops matching and the forecast falls back to the car.
    var solarForecastLocationID: String? {
        get {
            let value = d.string(forKey: "solar_forecast_location_id")
            return value?.isEmpty == false ? value : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                d.set(newValue, forKey: "solar_forecast_location_id")
            } else {
                d.removeObject(forKey: "solar_forecast_location_id")
            }
        }
    }

    /// The reader's own panel array, typed into Settings and kept on this Mac. The size stays
    /// local; only the tilt and direction go to Open-Meteo, to ask for the radiation on the panels.
    /// Zero means no array, and the forecast stays radiation only.
    var solarArrayKwp: Double {
        get { let value = d.double(forKey: "solar_array_kwp"); return value.isFinite ? max(0, value) : 0 }
        set { d.set(max(0, min(newValue, SolarArray.maximumKwp)), forKey: "solar_array_kwp") }
    }

    /// Panel tilt in degrees, 0 flat to 90 upright. 35 is a common roof pitch.
    var solarArrayTiltDegrees: Double {
        get { d.object(forKey: "solar_array_tilt_degrees") == nil ? 35 : d.double(forKey: "solar_array_tilt_degrees") }
        set { d.set(max(0, min(newValue, 90)), forKey: "solar_array_tilt_degrees") }
    }

    /// Panel direction in Open-Meteo's convention: 0 is south, -90 east, 90 west, ±180 north.
    var solarArrayAzimuthDegrees: Double {
        get { d.double(forKey: "solar_array_azimuth_degrees") }
        set { d.set(max(-180, min(newValue, 180)), forKey: "solar_array_azimuth_degrees") }
    }

    /// The array the forecast estimates output for, or nil while the size is zero.
    var solarArray: SolarArray? {
        SolarArray(kwp: solarArrayKwp, tiltDegrees: solarArrayTiltDegrees, azimuthDegrees: solarArrayAzimuthDegrees)
    }

    /// The consent that lets the planner send `startChargingOverride` on its own when the
    /// planned window opens and the vehicle is plugged in. Deliberately not transferable
    /// through settings archives and not part of any bulk-enable action.
    var plannerAutoStartEnabled: Bool { get { d.bool(forKey: "planner_auto_start_enabled") } set { d.set(newValue, forKey: "planner_auto_start_enabled") } }

    /// Opt-in sleep prevention. Off by default, and off unless auto-start is also on: with no
    /// command to send at the window, there is nothing to stay awake for. Not transferable
    /// with settings archives, like the auto-start consent it belongs to.
    var plannerKeepAwakeEnabled: Bool { get { d.bool(forKey: "planner_keep_awake_enabled") } set { d.set(newValue, forKey: "planner_keep_awake_enabled") } }

    /// The window the planner's auto-start is running for a vehicle. Its end is fixed when the
    /// start command is acknowledged, so slower-than-planned charging stops there instead of
    /// extending the plan. Persisted so a relaunch inside the window still ends it.
    func plannerWindow(for vin: String) -> DateInterval? {
        let key = vin.normalizedVIN
        guard !key.isEmpty,
              let all = d.dictionary(forKey: "planner_windows_v1") as? [String: [Double]],
              let pair = all[key], pair.count == 2 else { return nil }
        let start = Date(timeIntervalSince1970: pair[0])
        let end = Date(timeIntervalSince1970: pair[1])
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    func setPlannerWindow(_ window: DateInterval?, for vin: String) {
        let key = vin.normalizedVIN
        guard !key.isEmpty else { return }
        var all = d.dictionary(forKey: "planner_windows_v1") as? [String: [Double]] ?? [:]
        if let window {
            all[key] = [window.start.timeIntervalSince1970, window.end.timeIntervalSince1970]
        } else {
            all.removeValue(forKey: key)
        }
        d.set(all, forKey: "planner_windows_v1")
    }

    /// Well-to-wheel grid carbon intensity used only for the History tab's indicative
    /// "emissions avoided vs petrol" figure. Defaults to a middle-of-the-road European blend;
    /// a Nordic grid is far cleaner, a coal-heavy one dirtier, hence it is user-adjustable.
    var gridCarbonIntensityGramsPerKwh: Double { get { let value = d.double(forKey: "grid_carbon_intensity_g_per_kwh"); return value > 0 ? value : 120 } set { d.set(min(max(newValue, 0), 1_200), forKey: "grid_carbon_intensity_g_per_kwh") } }

    /// The optional Electricity Maps token behind the live grid-carbon line. The key itself is
    /// in the Keychain; this asks only whether one is saved. No key means no live line at all.
    var hasElectricityMapsKey: Bool { keychain.hasStoredElectricityMapsKey }
    func saveElectricityMapsKey(_ key: String) throws { try keychain.saveElectricityMapsKey(key) }
    func clearElectricityMapsKey() { try? keychain.deleteElectricityMapsKey() }
}
