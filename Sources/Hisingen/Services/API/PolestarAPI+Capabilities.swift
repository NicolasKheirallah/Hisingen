import Foundation

extension PolestarAPI {
    /// Returns the model-derived capability profile used by command and telemetry gates.
    func capabilityProfile(for vin: String? = nil) -> VehicleCapabilityProfile {
        let resolved = vin ?? selectedVIN
        return VehicleCapabilityProfile(modelName: identity(for: resolved).modelName, vin: resolved,
                                        advertised: cachedMyCars(for: resolved)?.advertisedCapabilities ?? [:])
    }

    func cachedMyCars(for vin: String?) -> VehicleOTACapabilities? {
        capabilityAuthority.cachedMyCars(for: vin)
    }

    func optionalBattery(enabled: Bool, vin: String, token: String) async throws -> GrpcBatteryExtras? {
        try Task.checkCancellation()
        guard enabled else { return nil }
        let epoch = sessionEpoch
        do {
            let value = try await grpc.fetchBattery(vin: vin, accessToken: token)
            try requireSession(epoch)
            return value
        } catch {
            try requireSession(epoch)
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional live battery service unavailable")
            return nil
        }
    }

    func optionalAvailability(enabled: Bool, vin: String, token: String) async throws -> GrpcAvailabilityReport {
        try Task.checkCancellation()
        guard enabled else {
            return GrpcAvailabilityReport(availability: .unknown, reportedAt: nil, unknownFields: [])
        }
        let epoch = sessionEpoch
        do {
            let report = try await grpc.fetchAvailabilityReport(vin: vin, accessToken: token)
            try requireSession(epoch)
            return report
        } catch {
            try requireSession(epoch)
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional availability service unavailable")
            return GrpcAvailabilityReport(availability: .unknown, reportedAt: nil, unknownFields: [])
        }
    }

    func targetSOC(
        enabled: Bool,
        vin: String,
        token: String,
        bypassCache: Bool = false
    ) async throws -> Int? {
        try Task.checkCancellation()
        guard enabled else { return nil }
        let epoch = sessionEpoch
        if !bypassCache,
           let cached = targetCache[vin], Date().timeIntervalSince(cached.fetchedAt) < 90 {
            return cached.value
        }
        let value: Int?
        do { value = try await grpc.fetchTargetSoc(vin: vin, accessToken: token) }
        catch {
            try requireSession(epoch)
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional target SOC service unavailable")
            value = nil
        }
        try requireSession(epoch)
        targetCache[vin] = (value, Date())
        return value
    }

    /// Probe-or-cache state, TTLs, backoff, and invalidation live in `capabilityAuthority`;
    /// the decision/record calls below never send a closure across the actor seam.
    func optionalCapability<Value: Sendable>(
        _ feature: AppFeature,
        key: String? = nil,
        enabled: Bool,
        vin: String,
        bypassCache: Bool = false,
        operation: @Sendable () async throws -> Value?
    ) async throws -> CapabilityState<Value> {
        try Task.checkCancellation()
        // The feature is off, so nothing was asked. This used to be reported as "not unavailable
        // and not unsupported", which reads as available; `.unknown` is what it always meant.
        guard enabled else { return .unknown }
        let reading = PolestarCapabilityAuthority.readingKey(for: feature, key: key)
        let epoch = sessionEpoch
        switch capabilityAuthority.decision(reading: reading, vin: vin, bypassCache: bypassCache) {
        case .serveCached(let value):
            return .available(value as? Value)
        case .backoff(let unsupported):
            return unsupported ? .unsupported : .unavailable
        case .probe:
            break
        }
        do {
            let value = try await operation()
            try requireSession(epoch)
            capabilityAuthority.recordSuccess(reading: reading, vin: vin, value: value)
            return .available(value)
        } catch {
            try requireSession(epoch)
            if Self.isGlobalFailure(error) { throw error }
            let unsupported = capabilityAuthority.recordFailure(reading: reading, vin: vin, error: error)
            logger.debug("Optional \(feature.rawValue, privacy: .public) capability unavailable")
            return unsupported ? .unsupported : .unavailable
        }
    }

    /// Software status and connectivity diagnostics for the augmented provider's overlay,
    /// served through the same optional-capability caches a full Polestar ID refresh uses,
    /// so portal-served refreshes pay at most one cached round trip per domain. A dead or
    /// dying session answers nil rather than throwing: the portal refresh that asked for
    /// this overlay already succeeded and must not be discarded over the consumer side.
    func consumerTelemetryOverlay(for vin: String, features: FeatureSelection) async -> ConsumerTelemetryOverlay? {
        do {
            try await refreshTokenIfNeeded()
            guard let token = accessToken else { return nil }
            let epoch = sessionEpoch
            let modelProfile = VehicleCapabilityProfile(modelName: identity(for: vin).modelName)
            async let software: CapabilityState<VehicleSoftwareInfo> = optionalCapability(
                .softwareUpdates, enabled: features.contains(.softwareUpdates), vin: vin
            ) {
                try await self.grpc.fetchSoftware(vin: vin, accessToken: token,
                                                  locale: preferences.interfaceLanguage.effectiveLanguageCode)
            }
            async let connectivity: CapabilityState<VehicleConnectivity> = optionalCapability(
                .connectivityDiagnostics,
                enabled: features.contains(.connectivityDiagnostics) && modelProfile.permits(.connectivity),
                vin: vin
            ) { try await self.grpc.fetchConnectivity(vin: vin, accessToken: token) }
            let overlay = ConsumerTelemetryOverlay(
                softwareInfo: try await software.value,
                connectivity: try await connectivity.value
            )
            try requireSession(epoch)
            return overlay
        } catch is CancellationError {
            return nil
        } catch {
            logger.debug("Consumer telemetry overlay unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }


}
