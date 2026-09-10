import Foundation

extension PendingCommandSummary {
    var confirmationFeatures: FeatureSelection? {
        guard supportsTelemetryConfirmation, let command else { return nil }
        return FeatureSelection(enabled: [command.feature])
    }

    var supportsTelemetryConfirmation: Bool {
        switch command {
        case .lock, .unlock,
             .openTailgate, .closeTailgate, .openWindows, .closeWindows,
             .startPreCleaning, .stopPreCleaning,
             .setChargeTarget, .setAmpLimit, .startChargingOverride:
            return true
        default:
            return false
        }
    }

    func updatingConfirmation(from state: VehicleState) -> PendingCommandSummary {
        guard status.isAwaiting, let command else { return self }
        let reading: VehicleReading
        let matches: Bool
        switch command {
        case .lock, .unlock:
            reading = .locks
            matches = state.exteriorStatus?.isLocked == (command != .unlock)
        case .openTailgate, .closeTailgate:
            reading = .openings
            let expected: OpeningState = command == .openTailgate ? .open : .closed
            matches = state.exteriorStatus?.openings.first {
                $0.opening == .tailgate
            }?.state == expected
        case .openWindows, .closeWindows:
            reading = .openings
            let windows: [VehicleOpening] = [.frontLeftWindow, .frontRightWindow, .rearLeftWindow, .rearRightWindow]
            let expected: OpeningState = command == .openWindows ? .open : .closed
            matches = windows.allSatisfy { window in
                state.exteriorStatus?.openings.first { $0.opening == window }?.state == expected
            }
        case .startPreCleaning, .stopPreCleaning:
            reading = .airQuality
            matches = state.airQuality?.cleaningState == (command == .startPreCleaning ? .on : .off)
        case .setChargeTarget(let target):
            reading = .charging
            matches = state.energy.targetPercentage == target
        case .setAmpLimit(let amps):
            reading = .charging
            matches = state.energy.currentLimitAmps == amps
        case .startChargingOverride:
            reading = .charging
            matches = state.energy.chargingState == .charging
                || state.energy.chargingState == .smartCharging
        default:
            return self
        }
        guard matches, state.hasFreshReading(reading),
              let date = state.reportedDate(for: reading), date > issuedAt else { return self }
        var updated = self
        updated.status = .confirmed(at: date)
        return updated
    }
}
