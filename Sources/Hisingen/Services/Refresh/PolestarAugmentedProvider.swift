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
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            logger.warning("Telemetry provider prepareSession non-fatal: \(String(describing: error), privacy: .private)")
        }
        do {
            try await commandProvider.prepareSession()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            logger.warning("Command provider prepareSession non-fatal: \(String(describing: error), privacy: .private)")
            if !telemetryOk { throw error }
        }
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        var commandAuthError: Error?
        do {
            try await commandProvider.authenticate(email: email, password: password, preferredVIN: preferredVIN, features: features)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            commandAuthError = error
            logger.warning("Command provider authenticate non-fatal: \(String(describing: error), privacy: .private)")
        }
        do {
            try await telemetryProvider.prepareSession()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            logger.warning("Telemetry provider prepareSession non-fatal: \(String(describing: error), privacy: .private)")
        }
        guard await hasWarmSession else {
            if let commandAuthError { throw commandAuthError }
            throw VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        }
    }

    /// Each half resolves its own stored credential, so a missing consumer token no longer
    /// means feeding the portal secret to the consumer API: the halves fail independently
    /// and `hasWarmSession` decides whether enough of the session survived.
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {
        var commandError: Error?
        do {
            try await commandProvider.restoreSession(preferredVIN: preferredVIN, features: features)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            commandError = error
            logger.warning("Command provider restoreSession non-fatal: \(String(describing: error), privacy: .private)")
        }
        var telemetryError: Error?
        do {
            try await telemetryProvider.restoreSession(preferredVIN: preferredVIN, features: features)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            telemetryError = error
            logger.warning("Telemetry provider restoreSession non-fatal: \(String(describing: error), privacy: .private)")
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
        var firstError: Error?
        do {
            try await telemetryProvider.signOut()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            firstError = firstError ?? error
        }
        do {
            try await commandProvider.signOut()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            firstError = firstError ?? error
        }
        if let firstError { throw firstError }
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        var telemetryOk = false
        do {
            try await telemetryProvider.reloadVehicleMetadata(vin: vin, features: features)
            telemetryOk = true
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            logger.warning("Telemetry reloadVehicleMetadata non-fatal: \(String(describing: error), privacy: .private)")
        }
        do {
            try await commandProvider.reloadVehicleMetadata(vin: vin, features: features)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            logger.warning("Command reloadVehicleMetadata non-fatal: \(String(describing: error), privacy: .private)")
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
            // Software status and connectivity diagnostics are consumer-API-only domains:
            // without this overlay a portal-served refresh reports them missing every time,
            // which pinned the "Showing last-known values" banner permanently.
            if await commandProvider.hasWarmSession,
               let overlay = await commandProvider.consumerTelemetryOverlay(for: vin, features: features) {
                state.softwareInfo = state.softwareInfo ?? overlay.softwareInfo
                state.connectivity = state.connectivity ?? overlay.connectivity
            }
            try Task.checkCancellation()
            if (features.contains(.chargingDetails) || features.contains(.batteryDiagnostics)),
               state.energy.batteryPercentage == nil, await commandProvider.hasWarmSession {
                do {
                    let fallback = try await commandProvider.fetchVehicleState(vin: vin, features: features)
                    let portalFreshness = state.freshness
                    let fallbackBattery = fallback.energy.batteryPercentage
                    state = state.mergingLastKnown(from: fallback, features: features)
                    if state.energy.batteryPercentage == nil { state.energy.batteryPercentage = fallbackBattery }
                    state.freshness = portalFreshness
                    if fallbackBattery != nil {
                        state.freshness.readingDates[.battery] = fallback.freshness.readingDates[.battery]
                        state.freshness.readingObservations?[.battery] = fallback.freshness.readingObservations?[.battery]
                        state.freshness.servedByFallback = true
                    }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                }
            }
            try Task.checkCancellation()
            return state
        } catch let primaryError {
            try Task.checkCancellation()
            if primaryError is CancellationError { throw primaryError }
            logger.warning("Primary Data Portal telemetry failed: \(String(describing: primaryError), privacy: .private). Trying Polestar ID fallback.")
            guard await commandProvider.hasWarmSession else { throw primaryError }
            do {
                var fallbackState = try await commandProvider.fetchVehicleState(vin: vin, features: features)
                fallbackState.freshness.servedByFallback = true
                return fallbackState
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                logger.error("Fallback Polestar ID telemetry also failed: \(String(describing: error), privacy: .private)")
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
