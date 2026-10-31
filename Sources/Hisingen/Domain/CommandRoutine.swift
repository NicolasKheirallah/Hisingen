import Foundation

/// A named, ordered sequence of Remote Commands sent to the selected vehicle one after another.
struct CommandRoutine: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var steps: [RemoteCommand]

    init(id: UUID = UUID(), name: String, steps: [RemoteCommand]) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// Steps the owner must approve once, when the routine starts. Anything above routine risk
    /// qualifies: unlocking, opening windows or the tailgate, starting the engine, honking.
    var stepsNeedingConfirmation: [RemoteCommand] {
        steps.filter { $0.risk != .routine }
    }

    /// The commands a routine can contain. Honk, flash, software installs, timers and charge
    /// locations stay out: they are one-off actions, not part of a sequence the reader would
    /// repeat. The charge targets are the common settings; anything else is a single command away.
    static func stepChoices(engineRuntimeMinutes: Int) -> [RemoteCommand] {
        let climate = RemoteCommand.startClimate(
            temperatureCelsius: 0, frontLeftSeat: .unspecified, frontRightSeat: .unspecified,
            rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified)
        let charge = stride(from: 50, through: 100, by: 10).map { RemoteCommand.setChargeTarget($0) }
        return [climate, .stopClimate, .startPreCleaning, .stopPreCleaning,
                .lock, .unlock, .openWindows, .closeWindows, .openTailgate, .closeTailgate,
                .startEngine(runtimeMinutes: engineRuntimeMinutes), .stopEngine] + charge
    }
}
