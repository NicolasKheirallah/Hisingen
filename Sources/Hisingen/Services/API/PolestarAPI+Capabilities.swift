import Foundation

extension PolestarAPI {
    /// Returns the model-derived capability profile used by command and telemetry gates.
    func capabilityProfile(for vin: String? = nil) -> VehicleCapabilityProfile {
        let resolved = vin ?? selectedVIN
        return VehicleCapabilityProfile(modelName: identity(for: resolved).modelName, vin: resolved)
    }

    func optionalBattery(enabled: Bool, vin: String, token: String) async throws -> GrpcBatteryExtras? {
        guard enabled else { return nil }
        do { return try await grpc.fetchBattery(vin: vin, accessToken: token) }
        catch {
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional live battery service unavailable")
            return nil
        }
    }

    func optionalAvailability(enabled: Bool, vin: String, token: String) async throws -> VehicleAvailability {
        guard enabled else { return .unknown }
        do { return try await grpc.fetchAvailability(vin: vin, accessToken: token) }
        catch {
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional availability service unavailable")
            return .unknown
        }
    }

    func targetSOC(enabled: Bool, vin: String, token: String) async throws -> Int? {
        guard enabled else { return nil }
        if let cached = targetCache[vin], Date().timeIntervalSince(cached.fetchedAt) < 90 {
            return cached.value
        }
        let value: Int?
        do { value = try await grpc.fetchTargetSoc(vin: vin, accessToken: token) }
        catch {
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional target SOC service unavailable")
            value = nil
        }
        targetCache[vin] = (value, Date())
        return value
    }

    func optionalCapability<Value: Sendable>(
        _ feature: AppFeature,
        key: String? = nil,
        enabled: Bool,
        vin: String,
        operation: @Sendable () async throws -> Value?
    ) async throws -> OptionalCapability<Value> {
        guard enabled else { return OptionalCapability(value: nil, unavailable: false) }
        let cacheKey = key ?? feature.rawValue
        let scopedCacheKey = "\(vin)|\(cacheKey)"
        if let cached = capabilityCache[scopedCacheKey], cached.expiresAt > Date(), cached.value != nil {
            return OptionalCapability(value: cached.value as? Value, unavailable: false)
        }
        if let until = capabilityBackoff[vin]?[cacheKey], until > Date() {
            return OptionalCapability(value: nil, unavailable: false)
        }
        do {
            let value = try await operation()
            capabilityBackoff[vin]?[cacheKey] = nil
            if value != nil {
                capabilityCache[scopedCacheKey] = CapabilityCacheEntry(
                    value: value,
                    expiresAt: Date().addingTimeInterval(Self.capabilityCacheLifetime(feature, key: cacheKey))
                )
            }
            return OptionalCapability(value: value, unavailable: false)
        } catch {
            if Self.isGlobalFailure(error) { throw error }
            let interval: TimeInterval
            // A service that answered UNIMPLEMENTED is not deployed for this backend/vehicle —
            // treat it like `incompatibleAPI` and stay away for hours, not minutes. (The gRPC
            // layer also skips it outright for the rest of the process via `unimplementedReadPaths`.)
            if case PolestarError.incompatibleAPI = error { interval = 6 * 60 * 60 }
            else if case PolestarError.grpcUnimplemented = error { interval = 6 * 60 * 60 }
            else if case PolestarError.invalidResponse = error { interval = 60 * 60 }
            else { interval = 5 * 60 }
            capabilityBackoff[vin, default: [:]][cacheKey] = Date().addingTimeInterval(interval)
            logger.debug("Optional \(feature.rawValue, privacy: .public) capability unavailable")
            return OptionalCapability(value: nil, unavailable: true)
        }
    }


}
