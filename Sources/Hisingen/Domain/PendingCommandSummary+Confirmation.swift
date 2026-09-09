import Foundation

extension PendingCommandSummary {
    func updatingConfirmation(from state: VehicleState) -> PendingCommandSummary {
        guard confirmedAt == nil, let command else { return self }
        let reading: VehicleReading
        let matches: Bool
        switch command {
        case .lock, .unlock:
            reading = .locks
            matches = state.exteriorStatus?.isLocked == (command == .lock)
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
        default:
            // Other responses lack a timestamped reading that proves the requested setting.
            return self
        }
        guard matches, state.hasFreshReading(reading),
              let date = state.reportedDate(for: reading), date > issuedAt else { return self }
        var updated = self
        updated.confirmedAt = date
        return updated
    }
}
