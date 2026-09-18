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
        let readingDate = state.reportedDate(for: proofReading)
        // Vehicle-stamped proof: the reading's own timestamp postdates the command, so the
        // value cannot be pre-command residue.
        let stampedDate: Date? = {
            guard state.hasFreshReading(proofReading, now: now),
                  let date = readingDate, date >= earliestConfirmationDate else { return nil }
            return date
        }()
        // A no-op write (setting a value the car already has) never advances the reading's
        // own timestamp, so the vehicle-stamped proof cannot ever pass. When the state was
        // fetched after the command and already shows the requested effect, the backend has
        // answered a post-command read with the requested value — that is confirmation too.
        // fetchedAt is app-local (no vehicle clock skew), so the command boundary is exact:
        // a fetch even slightly before the issue instant cannot prove the command. And a
        // refresh whose proving endpoint failed carries the previous value forward with a
        // fresh timestamp — that is not the backend re-answering.
        let fetchPostdatesCommand = !state.freshness.isCached
            && state.freshness.fetchedAt >= issuedAt
            && !state.freshness.unavailableFeatures.contains(command.feature)
        guard let confirmedAt = stampedDate ?? (fetchPostdatesCommand ? state.freshness.fetchedAt : nil) else {
            return self
        }
        var updated = self
        updated.status = .confirmed(at: confirmedAt)
        return updated
    }
}
