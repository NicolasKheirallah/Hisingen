import Foundation

/// One vehicle in a broadcast: what to send to, and what to call it in the report.
struct FleetCommandVehicle: Equatable, Sendable {
    let vin: String
    let displayName: String
}

/// What one vehicle's send ended as.
struct FleetCommandResult: Equatable, Sendable {
    let vehicle: FleetCommandVehicle
    let result: AutomationSendResult
}

/// The result of sending one command to every configured vehicle. The failures are kept
/// individually: "some car did not lock" is not actionable, "the Volvo did not lock, the service
/// refused the command" is.
struct FleetCommandReport: Equatable, Sendable {
    let command: RemoteCommand
    let results: [FleetCommandResult]

    var sent: [FleetCommandResult] { results.filter { $0.result.didSend } }
    var failed: [FleetCommandResult] { results.filter { !$0.result.didSend } }
    var sentCount: Int { sent.count }
    var vehiclesConsidered: Int { results.count }

    /// One line for the banner: how many answered, and which ones did not.
    func summary() -> String {
        guard vehiclesConsidered > 0 else {
            return L10n.text("No vehicles are configured for this account.")
        }
        guard !failed.isEmpty else {
            return L10n.format("%@ sent to %d vehicles.", command.title, sentCount)
        }
        let names = failed.map(\.vehicle.displayName).joined(separator: ", ")
        return L10n.format("%@ sent to %d of %d vehicles. Failed: %@.",
                           command.title, sentCount, vehiclesConsidered, names)
    }
}

/// Sends one command to every configured vehicle, one at a time, through the same queue and
/// cooldown an unattended send uses.
///
/// Sequential on purpose: the coordinator has one in-flight lane, so parallel sends would report
/// every vehicle after the first as busy. A vehicle that fails does not stop the rest – the point
/// of a broadcast is that the others still get the command, and the report names the one that
/// did not.
@MainActor
struct FleetCommandBroadcaster {
    typealias Vehicles = @MainActor () -> [FleetCommandVehicle]
    typealias Send = @MainActor (RemoteCommand, String) async -> AutomationSendResult

    let vehicles: Vehicles
    let send: Send

    func broadcast(_ command: RemoteCommand) async -> FleetCommandReport {
        var results: [FleetCommandResult] = []
        for vehicle in vehicles() {
            let result = await send(command, vehicle.vin)
            results.append(FleetCommandResult(vehicle: vehicle, result: result))
        }
        return FleetCommandReport(command: command, results: results)
    }
}
