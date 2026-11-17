import SwiftUI

struct VehicleReadinessCard: View {
    let state: VehicleState
    let lowBatteryThreshold: Int

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
                    }
                }
                if state.powertrain.hasElectricRange {
                    DepartureCheckDisclosure(state: state)
                }
            }
        }
    }
}
