import Foundation

extension CommandReceipt {
    var isClimateCommand: Bool {
        switch command {
        case .startClimate, .stopClimate: return true
        default: return false
        }
    }

    var confirmationFeatures: FeatureSelection? {
        guard supportsTelemetryConfirmation, let command else { return nil }
        return FeatureSelection(enabled: [command.feature])
    }

    var supportsTelemetryConfirmation: Bool {
        // Volvo's command API currently has no climate-status reading. Treat its provider
        // acknowledgement as terminal instead of polling for five minutes for data that
        // cannot arrive. A nil brand preserves legacy receipts written before this field.
        if providerBrand == .volvo, isClimateCommand { return false }
        switch command {
        case .lock, .unlock,
             .openTailgate, .closeTailgate, .openWindows, .closeWindows,
             .startClimate, .stopClimate,
             .startPreCleaning, .stopPreCleaning,
             .setChargeTarget, .setAmpLimit, .startChargingOverride:
            return true
        default:
            return false
        }
    }

    var confirmationConflictKey: String? { command?.confirmationConflictKey }

    func updatingConfirmation(
        from state: VehicleState,
        now: Date = Date(),
        timestampTolerance: TimeInterval = CommandReceipt.confirmationTimestampTolerance
    ) -> CommandReceipt {
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
        case .startClimate:
            reading = .climateStatus
            matches = state.isClimateActive
        case .stopClimate:
            reading = .climateStatus
            matches = state.climateStatus?.activity == .idle
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
        let earliestConfirmationDate = issuedAt.addingTimeInterval(-max(0, timestampTolerance))
        guard matches, state.hasFreshReading(reading, now: now),
              let date = state.reportedDate(for: reading),
              date >= earliestConfirmationDate else { return self }
        var updated = self
        updated.status = .confirmed(at: date)
        return updated
    }
}

extension RemoteCommand {
    /// Commands in one group describe a single desired end state. A newer command therefore
    /// supersedes any older pending command in the same group, including its opposite verb.
    var confirmationConflictKey: String? {
        switch self {
        case .startClimate, .stopClimate: return "climate"
        case .startPreCleaning, .stopPreCleaning: return "precleaning"
        case .lock, .lockReducedGuard, .unlock: return "locks"
        case .openTailgate, .closeTailgate: return "tailgate"
        case .openWindows, .closeWindows: return "windows"
        case .setChargeTarget: return "charge-target"
        case .setAmpLimit: return "amp-limit"
        case .startChargingOverride, .stopChargingOverride: return "charging-override"
        case .setGlobalChargeTimer: return "global-charge-timer"
        case .setClimateTimer, .deleteClimateTimer: return "climate-timer"
        case .scheduleOTA, .installOTANow, .cancelOTA: return "ota"
        case .startEngine, .stopEngine: return "engine"
        default: return nil
        }
    }
}
