import Foundation

extension PolestarAPI {
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        // Membership, not selection equality: the background garage scan re-points
        // `selectedVIN` while fetching other vehicles, and a strict equality check here
        // made a perfectly valid command for the user's car fail with "missing context"
        // mid-scan. Commands address their vehicle explicitly by VIN anyway.
        guard cars.contains(where: { $0.vin == vin }) else {
            throw RemoteCommandError.missingContext
        }
        guard !remoteCommandsInFlight.contains(vin) else { throw RemoteCommandError.busy }
        remoteCommandsInFlight.insert(vin)
        defer { remoteCommandsInFlight.remove(vin) }
        try await refreshTokenIfNeeded()
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        let profile = capabilityProfile(for: vin)
        guard profile.permits(command.requiredCapability) else {
            throw RemoteCommandError.unsupported
        }
        let adaptedCommand = command.adapted(to: profile)
        // Only the invocation-backed commands (locks, climate, windows, cabin cleaning,
        // locate) need the separate command-client token; charging, timers and OTA go
        // through with the primary session token, so don't spend a refresh round-trip on them.
        let commandToken: String?
        if adaptedCommand.requiresCommandClientAuthorization {
            switch await commandClientAuthorization() {
            case .authorized(let resolved):
                commandToken = resolved
            case .notAuthorized:
                throw RemoteCommandError.rejected(
                    L10n.text("Remote commands aren't authorized yet. Open Settings → Remote Controls and choose \"Authorize Remote Commands.\"")
                )
            case .unavailable:
                throw RemoteCommandError.rejected(
                    L10n.text("Couldn't confirm remote-command authorization with Polestar. Check your connection and try again.")
                )
            }
        } else {
            commandToken = nil
        }
        let result = try await grpc.executeRemoteCommand(
            adaptedCommand, vin: vin, accessToken: token,
            commandToken: commandToken
        )
        if case .setChargeTarget(let target) = adaptedCommand { targetCache[vin] = (target, Date()) }
        if case .setAmpLimit(let amps) = adaptedCommand {
            capabilityCache["\(vin)|amp-limit"] = CapabilityCacheEntry(value: amps, expiresAt: Date().addingTimeInterval(90))
        }
        if case .startClimate(let temp, let fl, let fr, _, _, let sw) = adaptedCommand {
            let status = VehicleClimateStatus(
                activity: .heating, timeRemainingMinutes: 30, timerTriggered: false,
                interiorTemperatureCelsius: nil,
                requestedTemperatureCelsius: Double(temp > 0 ? temp : 22.0),
                driverSeatHeatingLevel: fl.rawValue > 1 ? fl.rawValue - 1 : nil,
                passengerSeatHeatingLevel: fr.rawValue > 1 ? fr.rawValue - 1 : nil,
                steeringWheelHeatingLevel: sw.rawValue > 1 ? sw.rawValue - 1 : nil
            )
            capabilityCache["\(vin)|climate-status"] = CapabilityCacheEntry(value: status, expiresAt: Date().addingTimeInterval(90))
        } else if case .stopClimate = adaptedCommand {
            capabilityCache["\(vin)|climate-status"] = CapabilityCacheEntry(
                value: VehicleClimateStatus(activity: .idle, timeRemainingMinutes: nil, timerTriggered: false,
                                             interiorTemperatureCelsius: nil, requestedTemperatureCelsius: nil),
                expiresAt: Date().addingTimeInterval(90)
            )
        } else if case .startPreCleaning = adaptedCommand {
            capabilityCache["\(vin)|climate-status"] = CapabilityCacheEntry(
                value: VehicleClimateStatus(activity: .ventilating, timeRemainingMinutes: 10, timerTriggered: false,
                                             interiorTemperatureCelsius: nil, requestedTemperatureCelsius: nil),
                expiresAt: Date().addingTimeInterval(90)
            )
        } else if case .stopPreCleaning = adaptedCommand {
            capabilityCache["\(vin)|climate-status"] = CapabilityCacheEntry(
                value: VehicleClimateStatus(activity: .idle, timeRemainingMinutes: nil, timerTriggered: false,
                                             interiorTemperatureCelsius: nil, requestedTemperatureCelsius: nil),
                expiresAt: Date().addingTimeInterval(90)
            )
        }
        logger.info("Remote command accepted: \(adaptedCommand.identifier, privacy: .public)")
        return result
    }
}
