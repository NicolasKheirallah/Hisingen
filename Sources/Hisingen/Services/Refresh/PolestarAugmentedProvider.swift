import Foundation

/// An augmented provider combining the Polestar Developer Portal (EU Data Act M2M)
/// for robust, non-expiring background telemetry with the Polestar ID consumer adapter
/// for interactive remote controls and live gRPC streaming.
actor PolestarAugmentedProvider: VehicleProviding, VehicleLiveStreaming {
    nonisolated let brand: VehicleBrand = .polestar

    private let telemetryProvider: any VehicleProviding
    private let commandProvider: any VehicleProviding
    private let logger = AppLog.logger("polestar-augmented")

    init(telemetryProvider: any VehicleProviding, commandProvider: any VehicleProviding) {
        self.telemetryProvider = telemetryProvider
        self.commandProvider = commandProvider
    }

    var cars: [CarSummary] {
        get async {
            let portalCars = await telemetryProvider.cars
            if !portalCars.isEmpty { return portalCars }
            return await commandProvider.cars
        }
    }

    var hasWarmSession: Bool {
        get async {
            if await telemetryProvider.hasWarmSession { return true }
            return await commandProvider.hasWarmSession
        }
    }

    func resolvedVIN(preferred: String?) async -> String? {
        if let vin = await telemetryProvider.resolvedVIN(preferred: preferred) {
            return vin
        }
        return await commandProvider.resolvedVIN(preferred: preferred)
    }

    func prepareSession() async throws {
        var telemetryOk = false
        do {
            try await telemetryProvider.prepareSession()
            telemetryOk = true
        } catch {
            logger.warning("Telemetry provider prepareSession non-fatal: \(String(describing: error), privacy: .public)")
        }
        do {
            try await commandProvider.prepareSession()
        } catch {
            logger.warning("Command provider prepareSession non-fatal: \(String(describing: error), privacy: .public)")
            if !telemetryOk { throw error }
        }
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        var commandAuthError: Error?
        do {
            try await commandProvider.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: features)
        } catch {
            commandAuthError = error
            logger.warning("Command provider authenticate non-fatal: \(String(describing: error), privacy: .public)")
        }
        do {
            try await telemetryProvider.prepareSession()
        } catch {
            logger.warning("Telemetry provider prepareSession non-fatal: \(String(describing: error), privacy: .public)")
        }
        guard await hasWarmSession else {
            if let commandAuthError { throw commandAuthError }
            throw VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        }
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        var commandError: Error?
        do {
            try await commandProvider.restoreSession(token: token, preferredVIN: preferredVIN, features: features)
        } catch {
            commandError = error
            logger.warning("Command provider restoreSession non-fatal: \(String(describing: error), privacy: .public)")
        }
        var telemetryError: Error?
        do {
            try await telemetryProvider.restoreSession(token: token, preferredVIN: preferredVIN, features: features)
        } catch {
            telemetryError = error
            logger.warning("Telemetry provider restoreSession non-fatal: \(String(describing: error), privacy: .public)")
        }
        guard await hasWarmSession else {
            if let commandError { throw commandError }
            if let telemetryError { throw telemetryError }
            throw VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        }
    }

    func resetSession() async {
        await telemetryProvider.resetSession()
        await commandProvider.resetSession()
    }

    func signOut() async throws {
        try? await telemetryProvider.signOut()
        try? await commandProvider.signOut()
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        var telemetryOk = false
        do {
            try await telemetryProvider.reloadVehicleMetadata(vin: vin, features: features)
            telemetryOk = true
        } catch {
            logger.warning("Telemetry reloadVehicleMetadata non-fatal: \(String(describing: error), privacy: .public)")
        }
        do {
            try await commandProvider.reloadVehicleMetadata(vin: vin, features: features)
        } catch {
            logger.warning("Command reloadVehicleMetadata non-fatal: \(String(describing: error), privacy: .public)")
            if !telemetryOk { throw error }
        }
    }

    /// The Developer Portal is the primary telemetry source; the consumer API serves a
    /// refresh when the portal fails or returns empty telemetry and the user has a warm
    /// Polestar ID session. The primary error is re-thrown when the fallback also fails.
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        do {
            var state = try await telemetryProvider.fetchVehicleState(vin: vin, features: features)
            state.freshness.unavailableFeatures.removeAll { AppFeature.remoteFeatures.contains($0) }
            // The M2M surface carries no vehicle identity metadata. Fill those gaps from the
            // consumer adapter's prepared identity (no network call) so model name, plate,
            // and owner greeting survive portal-served refreshes.
            if let consumerIdentity = await commandProvider.identitySnapshot(for: vin, features: features) {
                state.identity = state.identity.overlayingGaps(from: consumerIdentity)
            }
            if state.energy.batteryPercentage == nil, await commandProvider.hasWarmSession {
                if let fallback = try? await commandProvider.fetchVehicleState(vin: vin, features: features) {
                    return fallback
                }
            }
            return state
        } catch let primaryError {
            logger.warning("Primary Data Portal telemetry failed: \(String(describing: primaryError), privacy: .public). Trying Polestar ID fallback.")
            guard await commandProvider.hasWarmSession else { throw primaryError }
            do {
                return try await commandProvider.fetchVehicleState(vin: vin, features: features)
            } catch {
                logger.error("Fallback Polestar ID telemetry also failed: \(String(describing: error), privacy: .public)")
                throw primaryError
            }
        }
    }

    /// In Augmented mode, Developer Portal M2M handles read telemetry exclusively, while all
    /// remote vehicle controls (climate, pre-cleaning, locks, horn/flash, charging timers)
    /// route directly to Polestar C3 Cloud (gRPC Invocation) via the command provider.
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        guard await commandProvider.hasWarmSession else {
            throw RemoteCommandError.rejected(
                L10n.text("Polestar ID session is required for remote vehicle controls.")
            )
        }
        return try await commandProvider.executeRemoteCommand(command, vin: vin)
    }

    // MARK: - VehicleLiveStreaming

    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        if let streamer = commandProvider as? any VehicleLiveStreaming {
            return try await streamer.liveVehicleUpdates(vin: vin, purpose: purpose)
        }
        throw VehicleServiceError.unsupported(provider: .polestar, service: "live streaming")
    }

    func refreshLiveStreamAuthorization() async throws {
        if let streamer = commandProvider as? any VehicleLiveStreaming {
            try await streamer.refreshLiveStreamAuthorization()
        }
    }
}
