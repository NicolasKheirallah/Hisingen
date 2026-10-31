import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    var remoteClimateTemperature: Double { get { let value = d.double(forKey: "remote_climate_temperature_v2"); let legacy = d.integer(forKey: "remote_climate_temperature"); return min(max(value > 0 ? value : (legacy == 0 ? 21 : Double(legacy)), 16), 30) } set { let value = (min(max(newValue, 16), 30) * 2).rounded() / 2; d.set(value, forKey: "remote_climate_temperature_v2"); d.set(Int(value.rounded()), forKey: "remote_climate_temperature") } }
    var remoteDriverSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_driver_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_driver_seat_heating") } }
    var remoteFrontRightSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_front_right_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_front_right_seat_heating") } }
    var remoteRearLeftSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_rear_left_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_rear_left_seat_heating") } }
    var remoteRearRightSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_rear_right_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_rear_right_seat_heating") } }
    var remoteSteeringWheelHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_steering_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_steering_heating") } }
    /// Remote-engine-start runtime the Controls tab last used, so the picker keeps the user's
    /// choice across panel opens instead of snapping back to 15 minutes each time.
    var remoteEngineRuntimeMinutes: Int { get { let value = d.integer(forKey: "remote_engine_runtime_minutes"); return [5, 10, 15].contains(value) ? value : 15 } set { d.set(newValue, forKey: "remote_engine_runtime_minutes") } }
    var calendarPreconditioningEnabled: Bool { get { d.bool(forKey: "calendar_preconditioning_enabled_v1") } set { d.set(newValue, forKey: "calendar_preconditioning_enabled_v1") } }
    var calendarPreconditioningLeadTimeMinutes: Int { get { let value = d.integer(forKey: "calendar_preconditioning_lead_minutes_v1"); return [5, 10, 15, 20, 30, 45, 60].contains(value) ? value : 20 } set { d.set(min(max(newValue, 1), 120), forKey: "calendar_preconditioning_lead_minutes_v1") } }
    var calendarPreconditioningCalendarIDs: Set<String> { get { Set(d.stringArray(forKey: "calendar_preconditioning_calendar_ids_v1") ?? []) } set { d.set(Array(newValue).sorted(), forKey: "calendar_preconditioning_calendar_ids_v1") } }
    var calendarPreconditioningFiredOccurrences: [String: Double] { get { d.dictionary(forKey: "calendar_preconditioning_fired_v1") as? [String: Double] ?? [:] } set { d.set(newValue, forKey: "calendar_preconditioning_fired_v1") } }
}
