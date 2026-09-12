import SwiftUI

@MainActor
struct LightingAndFluidCard: View {
    let state: VehicleState
    let features: FeatureSelection

    static func make(state: VehicleState, features: FeatureSelection) -> AnyView? {
        guard features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings) else { return nil }
        return AnyView(Self(state: state, features: features))
    }

    private var rows: [KVRow] {
        var rows: [KVRow] = []
        if !state.maintenance.service.fluidWarnings.isEmpty {
            for warning in state.maintenance.service.fluidWarnings {
                rows.append(KVRow(warning, L10n.text("Low Level"), symbol: "drop.triangle", warning: true))
            }
        } else {
            let reported = state.maintenance.details?.reportedWarnings.contains {
                $0 == .brakeFluid || $0 == .engineCoolant || $0 == .oil || $0 == .washerFluid
            } == true
            rows.append(KVRow(L10n.text("Fluid Warning Status"), reported ? L10n.text("No warning reported") : L10n.text("Unavailable"), symbol: "drop.fill", info: L10n.text("The providers report warning flags, not measured fluid levels.")))
        }
        if let health = state.maintenance.details {
            let warning = health.warnings.contains(.lowVoltageBattery)
            let reported = health.reportedWarnings.contains(.lowVoltageBattery)
            rows.append(KVRow(L10n.text("12V Battery"), warning ? L10n.text("Low Voltage") : (reported ? L10n.text("No warning reported") : L10n.text("Unavailable")), symbol: "minus.plus.batteryblock.fill", warning: warning))
        }
        if let failures = state.maintenance.details?.lightFailures, !failures.isEmpty {
            for failure in failures {
                rows.append(KVRow(failure, L10n.text("Fault"), symbol: "lightbulb.slash.fill", warning: true))
            }
        } else {
            let reported = state.maintenance.details?.reportedWarnings.contains(.exteriorLight) == true
            rows.append(KVRow(L10n.text("Lighting Warning Status"), reported ? L10n.text("No warning reported") : L10n.text("Unavailable"), symbol: "lightbulb.fill", info: L10n.text("Warning status only; this is not a live electrical test of every exterior lamp.")))
        }
        return rows
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "shield.lefthalf.filled", title: L10n.text("Vehicle Health & Lighting"), color: .yellow)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }
}
