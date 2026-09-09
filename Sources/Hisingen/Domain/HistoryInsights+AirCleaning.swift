import Foundation

extension HistoryInsights {
    struct AirCleaningCycle: Identifiable, Equatable {
        let id: String
        let startedAt: Date
        let endedAt: Date
        var observedMinutes: Int { Int(endedAt.timeIntervalSince(startedAt) / 60) }
    }

    static func airCleaningCycles(from events: [VehicleActivity], vin: String) -> [AirCleaningCycle] {
        let observations = events.filter { $0.vin == vin && $0.kind == .airCleaning }
            .sorted { $0.timestamp < $1.timestamp }
        var start: VehicleActivity?
        var cycles: [AirCleaningCycle] = []
        for event in observations {
            if event.after == AirCleaningState.on.rawValue {
                start = event
            } else if event.before == AirCleaningState.on.rawValue,
                      event.after == AirCleaningState.off.rawValue,
                      let began = start {
                let duration = event.timestamp.timeIntervalSince(began.timestamp)
                // Long gaps cannot establish that the same cleaning run was observed.
                if duration > 0, duration <= 2 * 3600 {
                    cycles.append(AirCleaningCycle(id: began.id, startedAt: began.timestamp, endedAt: event.timestamp))
                }
                start = nil
            } else {
                start = nil
            }
        }
        return cycles.reversed()
    }
}
