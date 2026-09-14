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
        return command?.descriptor.proofReading != nil
    }

    var confirmationConflictKey: String? { command?.confirmationConflictKey }

    func updatingConfirmation(
        from state: VehicleState,
        now: Date = Date(),
        timestampTolerance: TimeInterval = CommandReceipt.confirmationTimestampTolerance
    ) -> CommandReceipt {
        guard status.isAwaiting, let command, let proofReading = command.descriptor.proofReading else { return self }
        guard command.descriptor.isProvenBy(state) else { return self }
        let earliestConfirmationDate = issuedAt.addingTimeInterval(-max(0, timestampTolerance))
        guard state.hasFreshReading(proofReading, now: now),
              let date = state.reportedDate(for: proofReading),
              date >= earliestConfirmationDate else { return self }
        var updated = self
        updated.status = .confirmed(at: date)
        return updated
    }
}
