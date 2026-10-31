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
    /// The planner needs Swedish spot prices, so the feature switch alone is not enough.
    var smartChargingPlannerAvailable: Bool {
        marketCountry.offersMarketPricing && features.contains(.smartChargingPlanner)
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
            mode: marketCountry.offersMarketPricing ? electricityRateMode : .fixed, provider: electricityProvider, contract: electricityPriceContract,
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

    /// The consent that lets the planner send `startChargingOverride` on its own when the
    /// planned window opens and the vehicle is plugged in. Deliberately not transferable
    /// through settings archives and not part of any bulk-enable action.
    var plannerAutoStartEnabled: Bool { get { d.bool(forKey: "planner_auto_start_enabled") } set { d.set(newValue, forKey: "planner_auto_start_enabled") } }

    /// Well-to-wheel grid carbon intensity used only for the History tab's indicative
    /// "emissions avoided vs petrol" figure. Defaults to a middle-of-the-road European blend;
    /// a Nordic grid is far cleaner, a coal-heavy one dirtier, hence it is user-adjustable.
    var gridCarbonIntensityGramsPerKwh: Double { get { let value = d.double(forKey: "grid_carbon_intensity_g_per_kwh"); return value > 0 ? value : 120 } set { d.set(min(max(newValue, 0), 1_200), forKey: "grid_carbon_intensity_g_per_kwh") } }
}
