import Foundation

extension VehicleSchedule {
    func validationMessage(expectedKind: ScheduleKind) -> String? {
        guard kind == expectedKind else { return L10n.text("The schedule type does not match this command.") }
        guard let hour = startHour, let minute = startMinute,
              (0..<24).contains(hour), (0..<60).contains(minute) else {
            return L10n.text("Choose a valid start time for the schedule.")
        }
        if kind == .globalCharging {
            guard let hour = endHour, let minute = endMinute,
                  (0..<24).contains(hour), (0..<60).contains(minute) else {
                return L10n.text("Choose a valid end time for the charging window.")
            }
            if !weekdays.isEmpty { return L10n.text("Global charging windows repeat daily and do not support selected weekdays.") }
        }
        if let index, index < 0 { return L10n.text("The schedule index must not be negative.") }
        return nil
    }
}
