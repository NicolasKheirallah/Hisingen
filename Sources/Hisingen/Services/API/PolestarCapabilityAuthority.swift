import Foundation
import OSLog

struct PolestarReading<Value: Sendable>: Sendable {
    let key: String
    let feature: AppFeature
    fileprivate init(_ key: String, _ feature: AppFeature) {
        self.key = key
        self.feature = feature
    }

    static func legacy(_ key: String, feature: AppFeature) -> Self { Self(key, feature) }
}

extension PolestarReading where Value == Int {
    static var targetSOC: Self { Self("target-soc", .chargingDetails) }
    static var ampLimit: Self { Self("amp-limit", .chargingDetails) }
}
/// Same reading keys as the `Int` variants: the values now carry their unconsumed payload
/// fields alongside the decoded scalar, and the TTL and invalidation tables key on the
/// key strings, which do not change.
extension PolestarReading where Value == PCCSScalarRead {
    static var targetSOC: Self { Self("target-soc", .chargingDetails) }
    static var ampLimit: Self { Self("amp-limit", .chargingDetails) }
}
extension PolestarReading where Value == ExteriorSnapshot { static var exterior: Self { Self(AppFeature.exteriorStatus.rawValue, .exteriorStatus) } }
extension PolestarReading where Value == GrpcHealthReport { static var health: Self { Self(AppFeature.tyreAndWarnings.rawValue, .tyreAndWarnings) } }
extension PolestarReading where Value == VehicleSoftwareInfo { static var software: Self { Self(AppFeature.softwareUpdates.rawValue, .softwareUpdates) } }
extension PolestarReading where Value == [VehicleSchedule] {
    static var schedules: Self { Self(AppFeature.chargingSchedule.rawValue, .chargingSchedule) }
    static var climateTimers: Self { Self("climate-timers", .climateStatus) }
}
extension PolestarReading where Value == VehicleClimateStatus { static var climate: Self { Self("climate-status", .climateStatus) } }
extension PolestarReading where Value == GrpcOdometerReport { static var trips: Self { Self(AppFeature.tripMeters.rawValue, .tripMeters) } }
extension PolestarReading where Value == VehicleConnectivity { static var connectivity: Self { Self(AppFeature.connectivityDiagnostics.rawValue, .connectivityDiagnostics) } }
extension PolestarReading where Value == VehicleAirQuality { static var airQuality: Self { Self(AppFeature.airQuality.rawValue, .airQuality) } }
extension PolestarReading where Value == VehicleWeather { static var weather: Self { Self(AppFeature.vehicleWeather.rawValue, .vehicleWeather) } }
extension PolestarReading where Value == VehicleLocation { static var location: Self { Self(AppFeature.vehicleLocation.rawValue, .vehicleLocation) } }
extension PolestarReading where Value == [ChargeLocationSnapshot] { static var chargeLocations: Self { Self("charge-locations", .chargingSchedule) } }
extension PolestarReading where Value == VehicleOTACapabilities { static var myCars: Self { Self("my-cars", .softwareUpdates) } }

struct CapabilityCacheEntry {
    let value: (any Sendable)?
    let expiresAt: Date
    let fetchedAt: Date

    init(value: (any Sendable)?, expiresAt: Date, fetchedAt: Date = .distantPast) {
        self.value = value
        self.expiresAt = expiresAt
        self.fetchedAt = fetchedAt
    }
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
    private enum ReadingID: Hashable {
        case myCars
        case reading(String)

        init(_ value: String) {
            self = value == "my-cars" ? .myCars : .reading(value)
        }
    }

    private struct ScopedReading: Hashable {
        let vin: String
        let reading: ReadingID
    }

    private var generations: [String: UInt64] = [:]
    private var flights: [ScopedReading: any CapabilityFlight] = [:]
    private var cache: [ScopedReading: CapabilityCacheEntry] = [:]
    private var backoff: [String: [ReadingID: Date]] = [:]
    private var unsupported: Set<ScopedReading> = []
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
        flights.values.forEach { $0.cancel() }
        flights.removeAll()
        generations.removeAll()
        cache = [:]
        backoff = [:]
        unsupported = []
    }

    func join<Value: Sendable>(_ reading: PolestarReading<Value>, vin: String, startedAt: Date,
                               operation: @escaping @Sendable () async throws -> Value?) throws -> CapabilityTypedFlight<Value> {
        let key = scopedKey(vin: vin, reading: reading.key)
        if let existing = flights[key] {
            guard let typed = existing as? CapabilityTypedFlight<Value> else {
                throw PolestarError.invalidResponse(operation: "capability reading type")
            }
            typed.joinCount += 1
            return typed
        }
        let flight = CapabilityTypedFlight(startedAt: startedAt, task: Task { try await operation() })
        flights[key] = flight
        return flight
    }

    func generation(for vin: String) -> UInt64 { generations[vin] ?? 0 }

    func joinedCount<Value: Sendable>(_ reading: PolestarReading<Value>, vin: String) -> Int {
        (flights[scopedKey(vin: vin, reading: reading.key)] as? CapabilityTypedFlight<Value>)?.joinCount ?? 0
    }

    func finish<Value: Sendable>(_ reading: PolestarReading<Value>, vin: String,
                                 flight: CapabilityTypedFlight<Value>) {
        let key = scopedKey(vin: vin, reading: reading.key)
        if flights[key]?.id == flight.id { flights.removeValue(forKey: key) }
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

    enum TypedProbeDecision<Value: Sendable> {
        case serveCached(Value, fetchedAt: Date)
        case backoff(unsupported: Bool)
        case probe
    }

    func decision<Value: Sendable>(reading: PolestarReading<Value>, vin: String,
                                   bypassCache: Bool = false) -> TypedProbeDecision<Value> {
        switch decision(reading: reading.key, vin: vin, bypassCache: bypassCache) {
        case .serveCached(let value):
            guard let typed = value as? Value else { return .probe }
            return .serveCached(typed, fetchedAt: observedAt(reading: reading.key, vin: vin) ?? .distantPast)
        case .backoff(let unsupported): return .backoff(unsupported: unsupported)
        case .probe: return .probe
        }
    }

    func recordSuccess<Value: Sendable>(reading: PolestarReading<Value>, vin: String,
                                        value: Value?, fetchedAt: Date) {
        recordSuccess(reading: reading.key, vin: vin, value: value, fetchedAt: fetchedAt)
    }

    func decision(reading: String, vin: String, bypassCache: Bool = false) -> ProbeDecision {
        let scopedCacheKey = scopedKey(vin: vin, reading: reading)
        if !bypassCache,
           let cached = cache[scopedCacheKey], cached.expiresAt > now(), cached.value != nil {
            return .serveCached(cached.value!)
        }
        if let until = backoff[vin]?[ReadingID(reading)], until > now() {
            return .backoff(unsupported: unsupported.contains(scopedCacheKey))
        }
        return .probe
    }

    /// Records a successful probe: clears any backoff and, for a non-nil reading, caches it
    /// for the reading's TTL.
    func recordSuccess(reading: String, vin: String, value: (any Sendable)?, fetchedAt: Date? = nil) {
        let scopedCacheKey = scopedKey(vin: vin, reading: reading)
        backoff[vin]?[ReadingID(reading)] = nil
        unsupported.remove(scopedCacheKey)
        if value != nil {
            cache[scopedCacheKey] = CapabilityCacheEntry(
                value: value,
                expiresAt: now().addingTimeInterval(Self.lifetime(forReading: reading)),
                fetchedAt: fetchedAt ?? now()
            )
        } else {
            cache.removeValue(forKey: scopedCacheKey)
        }
    }

    func observedAt(reading: String, vin: String) -> Date? {
        cache[scopedKey(vin: vin, reading: reading)]?.fetchedAt
    }

    /// Records a failed probe and returns whether the reading is now marked unsupported
    /// (a long stand-down) rather than merely unavailable (a short one).
    @discardableResult
    func recordFailure(reading: String, vin: String, error: Error) -> Bool {
        let (interval, isUnsupported) = Self.backoffInterval(for: error)
        backoff[vin, default: [:]][ReadingID(reading)] = now().addingTimeInterval(interval)
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
        generations[vin, default: 0] &+= 1
        for key in Array(flights.keys) where key.vin == vin && key.reading != .myCars {
            flights.removeValue(forKey: key)?.cancel()
        }
        for key in cache.keys where key.vin == vin && key.reading != .myCars {
            cache[key] = nil
        }
        clearTransientBackoffAfterCommand(vin: vin)
    }

    func clearTransientBackoffAfterCommand(vin: String) {
        guard let current = backoff[vin] else { return }
        let retained = current.filter { key, _ in
            unsupported.contains(ScopedReading(vin: vin, reading: key))
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
        if reading == "target-soc" { return 90 }
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

    private func scopedKey(vin: String, reading: String) -> ScopedReading {
        ScopedReading(vin: vin, reading: ReadingID(reading))
    }
}

private protocol CapabilityFlight: AnyObject {
    var id: UUID { get }
    func cancel()
}

final class CapabilityTypedFlight<Value: Sendable>: CapabilityFlight, @unchecked Sendable {
    let id = UUID()
    var joinCount = 1
    let startedAt: Date
    let task: Task<Value?, Error>
    init(startedAt: Date, task: Task<Value?, Error>) {
        self.startedAt = startedAt
        self.task = task
    }
    func cancel() { task.cancel() }
}
