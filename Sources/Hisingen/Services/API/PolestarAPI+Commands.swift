import Foundation

extension PolestarAPI {
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        guard commandCatalog.implements(command) else { throw RemoteCommandError.unsupported }
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
        let adaptedCommand = command.adapted(to: profile, settings: cachedMyCars(for: vin)?.controlSettings)
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
            case .storageFailure:
                throw PolestarError.secureStorage
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
        // An acknowledgement is not a sensor reading. Force the follow-up to read the
        // backend instead of caching the requested settings or inventing climate state.
        targetCache[vin] = nil
        for key in capabilityCache.keys.filter({ $0.hasPrefix("\(vin)|") && !$0.hasSuffix("|my-cars") }) {
            capabilityCache[key] = nil
        }
        capabilityBackoff[vin] = nil
        logger.info("Remote command accepted: \(adaptedCommand.identifier, privacy: .public)")
        return result
    }
}
