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

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        var state = try await telemetryProvider.fetchVehicleState(vin: vin, features: features)
        state.freshness.unavailableFeatures.removeAll { AppFeature.remoteFeatures.contains($0) }
        return state
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        try await commandProvider.executeRemoteCommand(command, vin: vin)
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
