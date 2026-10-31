import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    /// Banner when the planned cheap-charging window opens. Respects quiet hours like
    /// every other alert, so an overnight window arrives in the morning list.
    var notifyPlannerWindowStart: Bool { get { boolDefaultTrue("notify_planner_window_start") } set { d.set(newValue, forKey: "notify_planner_window_start") } }
    /// How long before the cheap window opens the banner is posted; zero posts it as the
    /// window opens.
    var plannerWindowLeadMinutes: Int { get { let value = d.object(forKey: "planner_window_lead_minutes") as? Int; return min(max(value ?? 15, 0), 1_440) } set { d.set(min(max(newValue, 0), 1_440), forKey: "planner_window_lead_minutes") } }
    /// Banner after the daily fetch once tomorrow's prices have landed. Off by default –
    /// the information is rarely urgent enough to justify a daily ping.
    var notifyPlannerPricesPublished: Bool { get { d.bool(forKey: "notify_planner_prices_published") } set { d.set(newValue, forKey: "notify_planner_prices_published") } }

    /// Window-start notification dedupe: per-VIN record of when the last announced window
    /// *ends*. Keyed on the end because the plan is recomputed every tick and its start
    /// drifts while "charge now" is cheapest; a new banner is due only once a plan begins
    /// at or after the announced end. Key `…_v2`: v1 stored plan starts, which would be
    /// misread under the new semantics.
    func plannerNotifiedWindowEnd(for vin: String) -> Date? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty,
              let all = d.dictionary(forKey: "planner_notified_window_ends_v2") as? [String: Double] else { return nil }
        return all[key].map(Date.init(timeIntervalSince1970:))
    }
    func setPlannerNotifiedWindowEnd(_ date: Date?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var all = d.dictionary(forKey: "planner_notified_window_ends_v2") as? [String: Double] ?? [:]
        if let date { all[key] = date.timeIntervalSince1970 } else { all.removeValue(forKey: key) }
        d.set(all, forKey: "planner_notified_window_ends_v2")
    }
    /// Prices-published notification dedupe: zone → publication-day epoch day. One banner
    /// per zone per day, even across relaunches.
    func plannerPricesNotifiedDay(for zone: ElspotZone) -> Int? {
        let all = d.dictionary(forKey: "planner_prices_notified_v1") as? [String: Double]
        return all?[zone.rawValue].map(Int.init)
    }
    func setPlannerPricesNotifiedDay(_ day: Int?, for zone: ElspotZone) {
        var all = d.dictionary(forKey: "planner_prices_notified_v1") as? [String: Double] ?? [:]
        if let day { all[zone.rawValue] = Double(day) } else { all.removeValue(forKey: zone.rawValue) }
        d.set(all, forKey: "planner_prices_notified_v1")
    }

    var lowBatteryThreshold: Int { get { let value = d.integer(forKey: "low_battery_threshold"); return value == 0 ? 20 : min(max(value, 5), 50) } set { d.set(min(max(newValue, 5), 50), forKey: "low_battery_threshold") } }

    var notifyChargingStarted: Bool { get { boolDefaultTrue("notify_charging_started") } set { d.set(newValue, forKey: "notify_charging_started") } }
    var notifyChargingComplete: Bool { get { boolDefaultTrue("notify_charging_complete") } set { d.set(newValue, forKey: "notify_charging_complete") } }
    var notifyChargingProblem: Bool { get { boolDefaultTrue("notify_charging_problem") } set { d.set(newValue, forKey: "notify_charging_problem") } }
    var notifyLowBattery: Bool { get { boolDefaultTrue("notify_low_battery") } set { d.set(newValue, forKey: "notify_low_battery") } }
    var notifyPlugInReminder: Bool { get { boolDefaultTrue("notify_plugin_reminder") } set { d.set(newValue, forKey: "notify_plugin_reminder") } }
    var notifySoftwareUpdates: Bool { get { boolDefaultTrue("notify_software_updates") } set { d.set(newValue, forKey: "notify_software_updates") } }
    var notifyVehicleWarnings: Bool { get { boolDefaultTrue("notify_vehicle_warnings") } set { d.set(newValue, forKey: "notify_vehicle_warnings") } }
    var notifyOpeningsLeftOpen: Bool { get { boolDefaultTrue("notify_openings_left_open") } set { d.set(newValue, forKey: "notify_openings_left_open") } }
    var notifyServiceDue: Bool { get { boolDefaultTrue("notify_service_due") } set { d.set(newValue, forKey: "notify_service_due") } }
    var notifyStaleTelemetry: Bool { get { boolDefaultTrue("notify_stale_telemetry") } set { d.set(newValue, forKey: "notify_stale_telemetry") } }
    var notifySlowCharging: Bool { get { boolDefaultTrue("notify_slow_charging") } set { d.set(newValue, forKey: "notify_slow_charging") } }
    var notifyRainWithWindowsOpen: Bool { get { boolDefaultTrue("notify_rain_with_windows") } set { d.set(newValue, forKey: "notify_rain_with_windows") } }
    var notifyEveningUnlocked: Bool { get { boolDefaultTrue("notify_evening_unlocked") } set { d.set(newValue, forKey: "notify_evening_unlocked") } }
    var notifyChargerConnection: Bool { get { boolDefaultTrue("notify_charger_connection") } set { d.set(newValue, forKey: "notify_charger_connection") } }
    var notifyClimateChanges: Bool { get { boolDefaultTrue("notify_climate_changes") } set { d.set(newValue, forKey: "notify_climate_changes") } }
    /// Off by default: convenience mode is a normal state for some owners, so the alert is opt-in.
    var notifyUsageModeConvenience: Bool { get { d.bool(forKey: "notify_usage_convenience") } set { d.set(newValue, forKey: "notify_usage_convenience") } }
    /// One summary per day across all cars. Off by default; it is a daily ping, not an event.
    var notifyDailySummary: Bool { get { d.bool(forKey: "notify_daily_summary") } set { d.set(newValue, forKey: "notify_daily_summary") } }
    /// Local hour the daily summary is sent, 00–23. Default 08:00.
    var dailySummaryHour: Int { get { let value = d.object(forKey: "notify_daily_summary_hour") as? Int; return min(max(value ?? 8, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "notify_daily_summary_hour") } }

    /// True when at least one individual alert type is on. Used to decide whether asking the
    /// system for notification authorization is worthwhile.
    var anyNotificationAlertEnabled: Bool {
        notifyChargingStarted || notifyChargingComplete || notifyChargingProblem
            || notifyLowBattery || notifySoftwareUpdates || notifyVehicleWarnings
            || notifyRainWithWindowsOpen || notifyEveningUnlocked || notifyOpeningsLeftOpen
            || notifyServiceDue || notifyStaleTelemetry || notifySlowCharging
            || notifyPlugInReminder || notifyChargerConnection || notifyClimateChanges
            || notifyUsageModeConvenience || notifyDailySummary
    }
    var openingsAlertDelayMinutes: Int { get { let value = d.integer(forKey: "notify_openings_delay_minutes"); return min(max(value == 0 ? 15 : value, 5), 60) } set { d.set(min(max(newValue, 5), 60), forKey: "notify_openings_delay_minutes") } }
    var plugInReminderThreshold: Int { get { let value = d.integer(forKey: "notify_plugin_threshold"); return min(max(value == 0 ? 40 : value, 10), 80) } set { d.set(min(max(newValue, 10), 80), forKey: "notify_plugin_threshold") } }
    var eveningUnlockedStartHour: Int { get { let value = d.object(forKey: "notify_evening_unlocked_hour") as? Int; return min(max(value ?? 21, 18), 23) } set { d.set(min(max(newValue, 18), 23), forKey: "notify_evening_unlocked_hour") } }

    /// Audible cue on urgent notifications (security, warnings, charging problems).
    /// Routine informational banners stay silent regardless.
    var notifySounds: Bool { get { boolDefaultTrue("notify_sounds") } set { d.set(newValue, forKey: "notify_sounds") } }

    /// Hold non-urgent notifications during the configured window; urgent security
    /// banners bypass it. Hours are wall-clock, start == end disables the window.
    var quietHoursEnabled: Bool { get { d.bool(forKey: "notify_quiet_hours_enabled") } set { d.set(newValue, forKey: "notify_quiet_hours_enabled") } }
    var quietHoursStartHour: Int { get { let value = d.object(forKey: "notify_quiet_hours_start") as? Int; return min(max(value ?? 22, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "notify_quiet_hours_start") } }
    var quietHoursEndHour: Int { get { let value = d.object(forKey: "notify_quiet_hours_end") as? Int; return min(max(value ?? 7, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "notify_quiet_hours_end") } }

    /// Per-VIN notification mute: baselines keep advancing while muted so un-muting
    /// never replays a burst of stale edge events.
    func isMuted(vin: String) -> Bool {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return false }
        return (d.array(forKey: "muted_vehicle_vins_v1") as? [String])?.contains(key) ?? false
    }
    func setMuted(_ muted: Bool, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = d.array(forKey: "muted_vehicle_vins_v1") as? [String] ?? []
        if muted { if !values.contains(key) { values.append(key) } }
        else { values.removeAll { $0 == key } }
        d.set(values, forKey: "muted_vehicle_vins_v1")
    }

    /// Optional dock-tile badge with the number of vehicles that currently report
    /// active warnings or a triggered alarm. Off by default; the app runs as a menu-bar
    /// agent for most users, so the badge only shows when the dock icon does.
    var showWarningBadge: Bool { get { d.bool(forKey: "show_warning_badge") } set { d.set(newValue, forKey: "show_warning_badge") } }
}
