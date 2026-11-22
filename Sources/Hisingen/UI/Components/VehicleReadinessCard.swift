import SwiftUI

struct VehicleReadinessCard: View {
    let state: VehicleState
    let lowBatteryThreshold: Int

    @Environment(\.preferencesStore) private var preferences
    /// One long-lived EventKit store for the card's Add Reminder action, matching the
    /// calendar settings card's pattern.
    @State private var reminderWriter = ReminderWriter()

    /// The name the reminder carries: the reader's nickname, or the brand fallback
    /// the notification copy already uses.
    private var reminderVehicleName: String {
        let nickname = preferences.vehicleNickname(for: state.identity.vin)
        return nickname.isEmpty ? state.model.brand.displayName : nickname
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "checklist", title: L10n.text("Departure & Parking"), color: HisingenTheme.chartPositive)
                ForEach(VehicleReadiness.checks(state, lowBatteryThreshold: lowBatteryThreshold)) { check in
                    VStack(alignment: .leading, spacing: 2) {
                        KVRow(check.title, check.detail,
                              symbol: check.status == .attention ? "exclamationmark.circle" : check.status == .unknown ? "clock" : "checkmark.circle",
                              valueWarning: check.status == .attention)
                        if check.status == .unknown {
                            Text(L10n.text("Current condition is not confirmed by a fresh vehicle reading."))
                                .hisType(.micro).foregroundStyle(.secondary)
                        }
                        if check.id == "battery", check.status == .attention {
                            ReminderActionRow(title: "Add Plug-In Reminder") {
                                await reminderWriter.addPlugInReminder(
                                    vehicleName: reminderVehicleName,
                                    batteryPercent: state.energy.batteryPercentage
                                )
                            }
                        }
                    }
                }
                if state.powertrain.hasElectricRange {
                    DepartureCheckDisclosure(state: state)
                }
            }
        }
    }
}
