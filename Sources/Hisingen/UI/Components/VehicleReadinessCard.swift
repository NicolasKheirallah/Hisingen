import SwiftUI

struct VehicleReadinessCard: View {
    let state: VehicleState
    let lowBatteryThreshold: Int
    @State private var departure = Date().addingTimeInterval(3600)

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "checklist", title: L10n.text("Departure & Parking"), color: .teal)
                ForEach(VehicleReadiness.checks(state, lowBatteryThreshold: lowBatteryThreshold)) { check in
                    VStack(alignment: .leading, spacing: 2) {
                        KVRow(check.title, check.detail,
                              symbol: check.status == .attention ? "exclamationmark.circle" : check.status == .unknown ? "clock" : "checkmark.circle",
                              valueWarning: check.status == .attention)
                        if check.status == .unknown {
                            Text(L10n.text("Current condition is not confirmed by a fresh vehicle reading."))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if state.powertrain.hasElectricRange {
                    DisclosureGroup(L10n.text("Check charging before departure")) {
                        VStack(alignment: .leading, spacing: 6) {
                            DatePicker(L10n.text("Departure"), selection: $departure, in: Date()...,
                                       displayedComponents: .hourAndMinute)
                                .datePickerStyle(.compact)
                            Text(VehicleReadiness.chargingByDeparture(state, departure: departure))
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                            Text(state.chargingEstimateDestination).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.top, 6)
                    }
                }
            }
        }
    }
}
