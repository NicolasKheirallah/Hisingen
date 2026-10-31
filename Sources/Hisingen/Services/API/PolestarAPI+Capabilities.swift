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
        let state: CapabilityState<PCCSScalarRead> = try await optionalCapability(
            .chargingDetails, key: "target-soc", enabled: enabled, vin: vin, bypassCache: bypassCache
        ) {
            try await self.grpc.fetchTargetSoc(vin: vin, accessToken: token)
        }
        return state.value?.value
    }

    /// Probe-or-cache state, TTLs, backoff, and invalidation live in `capabilityAuthority`;
    /// the decision/record calls below never send a closure across the actor seam.
    func optionalCapability<Value: Sendable>(
        _ feature: AppFeature,
        key: String? = nil,
        enabled: Bool,
        vin: String,
        bypassCache: Bool = false,
        operation: @escaping @Sendable () async throws -> Value?
    ) async throws -> CapabilityState<Value> {
        let key = PolestarCapabilityAuthority.readingKey(for: feature, key: key)
        return try await optionalCapability(.legacy(key, feature: feature), enabled: enabled,
                                            vin: vin, bypassCache: bypassCache, operation: operation)
    }

    func optionalCapability<Value: Sendable>(
        _ reading: PolestarReading<Value>, enabled: Bool, vin: String, bypassCache: Bool = false,
        operation: @escaping @Sendable () async throws -> Value?
    ) async throws -> CapabilityState<Value> {
        try Task.checkCancellation()
        guard enabled else { return .unknown }
        let epoch = sessionEpoch
        let generation = capabilityAuthority.generation(for: vin)
        switch capabilityAuthority.decision(reading: reading, vin: vin, bypassCache: bypassCache) {
        case .serveCached(let value, let fetchedAt):
            return .cached(value, fetchedAt: fetchedAt)
        case .backoff(let unsupported):
            return unsupported ? .unsupported : .unavailable
        case .probe:
            break
        }
        let flight: CapabilityTypedFlight<Value>
        if bypassCache {
            flight = CapabilityTypedFlight(startedAt: now(), task: Task { try await operation() })
        } else {
            flight = try capabilityAuthority.join(reading, vin: vin, startedAt: now(), operation: operation)
        }
        do {
            let value = try await waitForCapabilityFlight(flight.task)
            try Task.checkCancellation()
            try requireSession(epoch)
            guard generation == capabilityAuthority.generation(for: vin) else { throw CancellationError() }
            if !bypassCache { capabilityAuthority.finish(reading, vin: vin, flight: flight) }
            capabilityAuthority.recordSuccess(reading: reading, vin: vin, value: value, fetchedAt: flight.startedAt)
            return .observed(value, fetchedAt: flight.startedAt)
        } catch {
            try requireSession(epoch)
            guard generation == capabilityAuthority.generation(for: vin) else { throw CancellationError() }
            if error is CancellationError { throw error }
            if !bypassCache { capabilityAuthority.finish(reading, vin: vin, flight: flight) }
            if Self.isGlobalFailure(error) { throw error }
            let unsupported = capabilityAuthority.recordFailure(reading: reading.key, vin: vin, error: error)
            logger.debug("Optional \(reading.feature.rawValue, privacy: .public) capability unavailable")
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
                                                  locale: self.preferences.interfaceLanguage.effectiveLanguageCode)
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
            logger.debug("Consumer telemetry overlay unavailable")
            return nil
        }
    }


}

private final class CapabilityWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Error>?
    private var result: Result<Value?, Error>?

    func install(_ continuation: CheckedContinuation<Value?, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func complete(_ result: Result<Value?, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private func waitForCapabilityFlight<Value: Sendable>(_ task: Task<Value?, Error>) async throws -> Value? {
    let waiter = CapabilityWaiter<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            waiter.install(continuation)
            Task { waiter.complete(await task.result) }
        }
    } onCancel: {
        waiter.complete(.failure(CancellationError()))
    }
}
