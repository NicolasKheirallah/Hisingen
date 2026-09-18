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
        do {
            try await telemetryProvider.prepareSession()
        } catch {
            logger.warning("Telemetry provider prepareSession non-fatal: \(String(describing: error), privacy: .public)")
        }
        try await commandProvider.prepareSession()
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        try await commandProvider.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: features)
        try? await telemetryProvider.prepareSession()
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        try? await telemetryProvider.restoreSession(token: token, preferredVIN: preferredVIN, features: features)
        try await commandProvider.restoreSession(token: token, preferredVIN: preferredVIN, features: features)
    }

    func resetSession() async {
        await telemetryProvider.resetSession()
        await commandProvider.resetSession()
    }

    func signOut() async throws {
        try? await telemetryProvider.signOut()
        try await commandProvider.signOut()
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        try? await telemetryProvider.reloadVehicleMetadata(vin: vin, features: features)
        try await commandProvider.reloadVehicleMetadata(vin: vin, features: features)
    }

    /// The Developer Portal is the primary telemetry source; the consumer API only serves a
    /// refresh when the portal fails and the user still has a warm Polestar ID session. The
    /// primary error is re-thrown when the fallback also fails – it names the configured API.
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        do {
            var state = try await telemetryProvider.fetchVehicleState(vin: vin, features: features)
            state.freshness.unavailableFeatures.removeAll { AppFeature.remoteFeatures.contains($0) }
            return state
        } catch {
            logger.warning("Primary Data Portal telemetry failed: \(String(describing: error), privacy: .public). Trying Polestar ID fallback.")
            guard await commandProvider.hasWarmSession else { throw error }
            do {
                return try await commandProvider.fetchVehicleState(vin: vin, features: features)
            } catch {
                logger.error("Fallback Polestar ID telemetry also failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
    }

    /// Portal-supported commands (climate, cabin cleaning, charging, schedules, charge
    /// locations) go to the Developer Portal first, falling back to the consumer API when the
    /// portal cannot serve them. Locks, horn, and other consumer-exclusive commands skip the
    /// portal entirely – the EU Data Act surface does not expose them.
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        let portalCatalog = ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .dataPortal)
        if portalCatalog.implements(command) {
            do {
                return try await telemetryProvider.executeRemoteCommand(command, vin: vin)
            } catch {
                logger.warning("Primary Data Portal command failed: \(String(describing: error), privacy: .public). Trying Polestar ID fallback.")
                guard await commandProvider.hasWarmSession else { throw error }
                return try await commandProvider.executeRemoteCommand(command, vin: vin)
            }
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
