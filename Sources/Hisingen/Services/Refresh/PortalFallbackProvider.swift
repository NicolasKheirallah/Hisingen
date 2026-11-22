import Foundation

/// `.dataPortal` with a way out.
///
/// Developer Portal mode used to have no fallback at all: a revoked grant, a spent daily quota,
/// or a missing credential left every card dark even when a Polestar ID session was warm.
/// This provider keeps the portal as the primary — read-only, as the mode promises — and asks
/// the consumer session to serve a refresh the portal cannot. On a successful portal refresh
/// it still fills the domains the portal structurally cannot serve (software and connectivity)
/// from the consumer overlay, using `ProviderDomainSupportMap` rather than a hard-coded list.
actor PortalFallbackProvider: VehicleProviding, VehicleMetadataProviding {
    nonisolated let brand: VehicleBrand = .polestar

    private let portal: any VehicleProviding
    private let consumer: any VehicleProviding
    private let entitlementProbe: @Sendable (Date) async -> PortalEntitlement
    private let now: @Sendable () -> Date
    private let logger = AppLog.logger("polestar-portal-fallback")

    /// A probe is a network round trip, so its answer is reused for a few minutes. The portal's
    /// entitlement changes at human speed; a refresh loop must not turn it into a probe loop.
    private static let entitlementLifetime: TimeInterval = 300
    private var cachedEntitlement: PortalEntitlement?
    private var entitlementCheckedAt: Date?

    init(
        portal: any VehicleProviding,
        consumer: any VehicleProviding,
        now: @escaping @Sendable () -> Date = { Date() },
        entitlementProbe: (@Sendable (Date) async -> PortalEntitlement)? = nil
    ) {
        self.portal = portal
        self.consumer = consumer
        self.now = now
        if let entitlementProbe {
            self.entitlementProbe = entitlementProbe
        } else if let reporting = portal as? any PortalEntitlementReporting {
            self.entitlementProbe = { date in await reporting.probeEntitlement(now: date) }
        } else {
            // An adapter without a probe can only answer the configuration question; a bare
            // `entitled` would let the portal attempt and fail on its own terms, which is the
            // pre-existing behaviour.
            self.entitlementProbe = { _ in .entitled }
        }
    }

    // MARK: - VehicleProviding

    var cars: [CarSummary] {
        get async {
            let portalCars = await portal.cars
            if !portalCars.isEmpty { return portalCars }
            return await consumer.cars
        }
    }

    var hasWarmSession: Bool {
        get async {
            if await portal.hasWarmSession { return true }
            return await consumer.hasWarmSession
        }
    }

    func resolvedVIN(preferred: String?) async -> String? {
        if let vin = await portal.resolvedVIN(preferred: preferred) { return vin }
        return await consumer.resolvedVIN(preferred: preferred)
    }

    func prepareSession() async throws {
        var portalPrepared = false
        do {
            try await portal.prepareSession()
            portalPrepared = true
        } catch {
            try rethrowIfCancelled(error)
            logger.notice("Portal prepareSession failed; consumer fallback remains available: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
        }
        do {
            try await consumer.prepareSession()
        } catch {
            try rethrowIfCancelled(error)
            if !portalPrepared { throw error }
        }
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        // Developer Portal mode stores an M2M credential pair; a password belongs to Polestar ID
        // and switching the mode is the reader's decision, not a silent side effect of a sign-in.
        try await portal.authenticate(email: email, password: password,
                                       preferredVIN: preferredVIN, features: features)
    }

    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {
        var portalError: Error?
        do {
            try await portal.restoreSession(preferredVIN: preferredVIN, features: features)
        } catch {
            try rethrowIfCancelled(error)
            portalError = error
        }
        var consumerError: Error?
        do {
            try await consumer.restoreSession(preferredVIN: preferredVIN, features: features)
        } catch {
            try rethrowIfCancelled(error)
            consumerError = error
        }
        guard await hasWarmSession else {
            if let portalError { throw portalError }
            if let consumerError { throw consumerError }
            throw VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        }
    }

    func resetSession() async {
        cachedEntitlement = nil
        entitlementCheckedAt = nil
        await portal.resetSession()
        await consumer.resetSession()
    }

    func signOut() async throws {
        var firstError: Error?
        do {
            try await portal.signOut()
        } catch {
            try rethrowIfCancelled(error)
            firstError = firstError ?? error
        }
        do {
            try await consumer.signOut()
        } catch {
            try rethrowIfCancelled(error)
            firstError = firstError ?? error
        }
        if let firstError { throw firstError }
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        var portalOk = false
        do {
            try await portal.reloadVehicleMetadata(vin: vin, features: features)
            portalOk = true
        } catch {
            try rethrowIfCancelled(error)
        }
        do {
            try await consumer.reloadVehicleMetadata(vin: vin, features: features)
        } catch {
            try rethrowIfCancelled(error)
            if !portalOk { throw error }
        }
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        let entitlement = await currentEntitlement()
        let consumerWarm = await consumer.hasWarmSession
        switch PortalFallbackPolicy.decide(entitlement: entitlement, consumerWarm: consumerWarm, now: now()) {
        case .fallbackOnly(let reason):
            return try await servedByConsumer(vin: vin, features: features, reason: reason)

        case .portalFirst:
            do {
                var state = try await portal.fetchVehicleState(vin: vin, features: features)
                state = await overlayingConsumerOnlyDomains(state, vin: vin, features: features)
                state.providerReport = ProviderCapabilityReport(
                    providerName: VehicleBrand.polestar.displayName,
                    channel: .polestarDataPortal,
                    recordedAt: now(),
                    supportedDomains: ProviderDomainSupportMap.domains(for: .polestarDataPortal),
                    servedByFallback: false,
                    connectionNote: entitlement == .entitled ? nil : entitlement.explanation)
                try Task.checkCancellation()
                return state
            } catch {
                try rethrowIfCancelled(error)
                logger.warning("Developer Portal telemetry failed; trying Polestar ID: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
                guard await consumer.hasWarmSession else { throw error }
                return try await servedByConsumer(vin: vin, features: features,
                                                  reason: entitlement.explanation
                                                    ?? L10n.text("The Developer Portal refresh failed."))
            }
        }
    }

    /// The portal is read-only and cannot serve these domains at all. On a mode whose catalog
    /// refuses writes this does not enable a command; it only stops the portal refresh from
    /// reporting a consumer-only domain as missing every time.
    private func overlayingConsumerOnlyDomains(
        _ state: VehicleState, vin: String, features: FeatureSelection
    ) async -> VehicleState {
        let missing = ProviderDomainSupportMap.domainsMissing(
            from: .polestarDataPortal, suppliedBy: .polestarID)
        guard !missing.isEmpty, await consumer.hasWarmSession else { return state }
        var merged = state
        if let overlay = await consumer.consumerTelemetryOverlay(for: vin, features: features) {
            if missing.contains(.software) { merged.softwareInfo = merged.softwareInfo ?? overlay.softwareInfo }
            if missing.contains(.connectivity) { merged.connectivity = merged.connectivity ?? overlay.connectivity }
        }
        if let identity = await consumer.identitySnapshot(for: vin, features: features) {
            merged.identity = merged.identity.overlayingGaps(from: identity)
        }
        return merged
    }

    private func servedByConsumer(
        vin: String, features: FeatureSelection, reason: String?
    ) async throws -> VehicleState {
        var state = try await consumer.fetchVehicleState(vin: vin, features: features)
        state.freshness.servedByFallback = true
        state.providerReport = ProviderCapabilityReport(
            providerName: VehicleBrand.polestar.displayName,
            channel: .polestarID,
            recordedAt: now(),
            supportedDomains: ProviderDomainSupportMap.domains(for: .polestarID),
            servedByFallback: true,
            connectionNote: reason)
        return state
    }

    private func currentEntitlement() async -> PortalEntitlement {
        let current = now()
        if let cachedEntitlement, let checked = entitlementCheckedAt,
           current.timeIntervalSince(checked) < Self.entitlementLifetime {
            return cachedEntitlement
        }
        let value = await entitlementProbe(current)
        cachedEntitlement = value
        entitlementCheckedAt = current
        return value
    }

    // MARK: - VehicleMetadataProviding

    func identitySnapshot(for vin: String, features: FeatureSelection) async -> VehicleIdentitySnapshot? {
        await consumer.identitySnapshot(for: vin, features: features)
    }

    func consumerTelemetryOverlay(for vin: String, features: FeatureSelection) async -> ConsumerTelemetryOverlay? {
        await consumer.consumerTelemetryOverlay(for: vin, features: features)
    }

    // MARK: - RemoteCommandExecuting

    /// Developer Portal mode is read-only by contract. The command catalog already refuses
    /// every command in this mode; refusing here too keeps a caller that bypassed the catalog
    /// from turning a fallback into a write path.
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        throw RemoteCommandError.rejected(
            L10n.text("Developer Portal is read-only. Remote controls need Polestar ID or Augmented mode."))
    }
}
