import SwiftUI

@MainActor
struct ExceptionsCard: View {
    let state: VehicleState
    let features: FeatureSelection
    let dismissedSoftwareEventIdentifier: String?

    static func make(state: VehicleState, features: FeatureSelection, dismissedSoftwareEventIdentifier: String?) -> AnyView? {
        let card = Self(state: state, features: features, dismissedSoftwareEventIdentifier: dismissedSoftwareEventIdentifier)
        guard !card.rows.isEmpty else { return nil }
        return AnyView(card)
    }

    private var rows: [KVRow] {
        var rows: [KVRow] = []
        if features.contains(.vehicleAvailability), state.identity.availability != .unknown, state.identity.availability != .available {
            rows.append(KVRow(L10n.text("Cloud Connectivity"), state.identity.availability.displayName, symbol: "antenna.radiowaves.left.and.right", valueWarning: true))
        }
        if features.contains(.vehicleHealth) {
            if state.maintenance.service.serviceWarning {
                rows.append(KVRow(L10n.text("Service Inspection Warning"), L10n.text("Action Required"), symbol: "exclamationmark.triangle", warning: true))
            }
            for warning in state.maintenance.service.fluidWarnings {
                rows.append(KVRow(warning, L10n.text("Low Level"), symbol: "drop.triangle", warning: true))
            }
        }
        if features.contains(.exteriorStatus), let exterior = state.exteriorStatus {
            for opening in exterior.itemsNeedingAttention {
                rows.append(KVRow(L10n.format("%@ Open", opening.displayName), L10n.text("Warning"), symbol: "exclamationmark.circle.fill", warning: true))
            }
            if exterior.alarmTriggered == true {
                rows.append(KVRow(L10n.text("Vehicle Alarm Triggered"), L10n.text("Active Alarm"), symbol: "speaker.wave.3.fill", warning: true))
            }
        }
        if features.contains(.tyreAndWarnings), let tyres = state.maintenance.details?.tyres {
            let count = tyres.filter { $0.warning.needsAttention }.count
            if count > 0 {
                rows.append(KVRow(L10n.text("Tyre Pressure"), L10n.format("%d tyre(s) need attention", count), symbol: "circle.grid.2x2", warning: true))
            }
        }
        if features.contains(.tyreAndWarnings) || features.contains(.vehicleHealth), let health = state.maintenance.details {
            for warning in health.warnings {
                rows.append(KVRow(warning.displayName, L10n.text("Warning"), symbol: "exclamationmark.triangle.fill", warning: true))
            }
        }
        if features.contains(.softwareUpdates), let software = state.softwareInfo,
           software.hasActionableFailure(), dismissedSoftwareEventIdentifier != software.eventIdentifier {
            rows.append(KVRow(L10n.text("Vehicle Software"), L10n.text("Update Failed"), symbol: "arrow.triangle.2.circlepath", warning: true))
        }
        return rows
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "exclamationmark.triangle.fill", title: L10n.text("Needs Attention"), color: HisingenTheme.semanticWarning, isSemantic: true)
                VStack(spacing: 6) { ForEach(rows.indices, id: \.self) { rows[$0] } }
            }
        }
    }
}
