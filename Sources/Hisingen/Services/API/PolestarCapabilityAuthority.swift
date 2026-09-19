import Foundation
import OSLog

struct CapabilityCacheEntry {
    let value: (any Sendable)?
    let expiresAt: Date
}

/// One authority for "can the Polestar backend do X for this VIN": the probe-or-cache
/// decision, the reading-key aliasing, the per-reading TTL table, per-reading backoff after
/// a failed probe, and command-time invalidation. Extracted from `PolestarAPI`, where the
/// state was three loose dictionaries, the policy was two statics, and invalidation was
/// string-prefix surgery over the dictionaries.
///
/// ## Synchronization
///
/// `@unchecked Sendable` by confinement: the authority is created, mutated, and read only
/// from the provider actor that owns it, so no lock is needed. Its closures are `@Sendable`
/// because they hop back to that actor.
final class PolestarCapabilityAuthority: @unchecked Sendable {
    private var cache: [String: CapabilityCacheEntry] = [:]
    private var backoff: [String: [String: Date]] = [:]
    private var unsupported: Set<String> = []
    private let now: () -> Date
    private let logger: Logger

    init(now: @escaping () -> Date = Date.init,
         logger: Logger = AppLog.logger("polestar-api")) {
        self.now = now
        self.logger = logger
    }

    /// True when nothing is cached and no backoff or unsupported marker is held.
    var isEmpty: Bool {
        cache.isEmpty && backoff.isEmpty && unsupported.isEmpty
    }

    func reset() {
        cache = [:]
        backoff = [:]
        unsupported = []
    }

    // MARK: - The probe-or-cache decision

    /// What the caller should do for a reading this round. Serves the cached value while it
    /// is fresh, reports a backoff window without probing again, or asks for a probe. The
    /// transport stays with the owning actor; the state and the policy stay here, so no
    /// closure has to cross the actor seam.
    enum ProbeDecision {
        case serveCached(any Sendable)
        case backoff(unsupported: Bool)
        case probe
    }

    func decision(reading: String, vin: String, bypassCache: Bool = false) -> ProbeDecision {
        let scopedCacheKey = scopedKey(vin: vin, reading: reading)
        if !bypassCache,
           let cached = cache[scopedCacheKey], cached.expiresAt > now(), cached.value != nil {
            return .serveCached(cached.value!)
        }
        if let until = backoff[vin]?[reading], until > now() {
            return .backoff(unsupported: unsupported.contains(scopedCacheKey))
        }
        return .probe
    }

    /// Records a successful probe: clears any backoff and, for a non-nil reading, caches it
    /// for the reading's TTL.
    func recordSuccess(reading: String, vin: String, value: (any Sendable)?) {
        let scopedCacheKey = scopedKey(vin: vin, reading: reading)
        backoff[vin]?[reading] = nil
        unsupported.remove(scopedCacheKey)
        if value != nil {
            cache[scopedCacheKey] = CapabilityCacheEntry(
                value: value,
                expiresAt: now().addingTimeInterval(Self.lifetime(forReading: reading))
            )
        }
    }

    /// Records a failed probe and returns whether the reading is now marked unsupported
    /// (a long stand-down) rather than merely unavailable (a short one).
    @discardableResult
    func recordFailure(reading: String, vin: String, error: Error) -> Bool {
        let (interval, isUnsupported) = Self.backoffInterval(for: error)
        backoff[vin, default: [:]][reading] = now().addingTimeInterval(interval)
        let scopedCacheKey = scopedKey(vin: vin, reading: reading)
        if isUnsupported { unsupported.insert(scopedCacheKey) }
        else { unsupported.remove(scopedCacheKey) }
        return isUnsupported
    }

    /// A service that answered UNIMPLEMENTED is not deployed for this backend/vehicle:
    /// stay away for hours, not minutes. (The gRPC layer also remembers the specific
    /// backend/VIN/path for 24 hours.)
    private static func backoffInterval(for error: Error) -> (interval: TimeInterval, unsupported: Bool) {
        if case PolestarError.incompatibleAPI = error { return (6 * 60 * 60, true) }
        if case PolestarError.grpcUnimplemented = error { return (6 * 60 * 60, true) }
        if case PolestarError.permissionDenied = error { return (6 * 60 * 60, true) }
        if case PolestarError.invalidResponse = error { return (60 * 60, false) }
        return (5 * 60, false)
    }

    // MARK: - Command-time invalidation

    /// An acknowledgement is not a sensor reading. Drops every cached reading for the VIN
    /// that a command could have changed, keeping only my-cars metadata, and lifts the
    /// transient (non-unsupported) backoffs so the follow-up refresh probes afresh.
    func invalidateTransientCaches(forVIN vin: String) {
        for key in cache.keys where key.hasPrefix("\(vin)|") && !key.hasSuffix("|my-cars") {
            cache[key] = nil
        }
        clearTransientBackoffAfterCommand(vin: vin)
    }

    func clearTransientBackoffAfterCommand(vin: String) {
        guard let current = backoff[vin] else { return }
        let retained = current.filter { key, _ in
            unsupported.contains(scopedKey(vin: vin, reading: key))
        }
        backoff[vin] = retained.isEmpty ? nil : retained
    }

    // MARK: - my-cars metadata

    func cachedMyCars(for vin: String?) -> VehicleOTACapabilities? {
        guard let vin, let cached = cache[scopedKey(vin: vin, reading: "my-cars")],
              cached.expiresAt > now() else { return nil }
        return cached.value as? VehicleOTACapabilities
    }

    // MARK: - Policy

    /// Maps a remote-command feature onto the reading that carries its evidence, so lock
    /// availability reads the exterior report once instead of probing per feature.
    static func readingKey(for feature: AppFeature, key: String? = nil) -> String {
        if let key { return key }
        switch feature {
        case .remoteLocks, .remoteWindows: return AppFeature.exteriorStatus.rawValue
        case .remoteOTA: return AppFeature.softwareUpdates.rawValue
        case .remoteSchedules: return AppFeature.chargingSchedule.rawValue
        case .remotePreCleaning: return AppFeature.airQuality.rawValue
        default: return feature.rawValue
        }
    }

    /// How long a successful reading may serve follow-up questions, per reading kind.
    /// Short for values a command or a user action can change within seconds; longer for
    /// slowly-varying vehicle facts.
    static func lifetime(forReading reading: String) -> TimeInterval {
        if reading == "climate-status" { return 15 }
        if reading == "amp-limit" || [AppFeature.exteriorStatus, .airQuality, .vehicleLocation,
                                      .tripMeters, .connectivityDiagnostics].map(\.rawValue).contains(reading) {
            return 30
        }
        if reading == "climate-timers" || reading == "charge-locations"
            || reading == AppFeature.chargingSchedule.rawValue { return 60 }
        if [AppFeature.vehicleWeather, .tyreAndWarnings, .vehicleHealth]
            .map(\.rawValue).contains(reading) { return 300 }
        return 60 * 60
    }

    private func scopedKey(vin: String, reading: String) -> String { "\(vin)|\(reading)" }
}
