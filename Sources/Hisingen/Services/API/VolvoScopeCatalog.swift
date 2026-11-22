import Foundation

/// The provider-side half of the Volvo capability inspector.
///
/// Volvo states two things the app used to throw away: the scopes an authorization actually
/// granted (the token response's `scope`), and, per wrapped field, a `status` plus
/// `unavailableReason` when the car cannot answer. Both are mapped here into one brand-neutral
/// report, so the UI shows what Volvo said instead of a generic unavailable badge. Nothing in
/// this type performs a request; it only translates a payload the adapter already decoded.
enum VolvoScopeCatalog {
    struct DomainScopes {
        let domain: ProviderDomain
        let scopes: [String]
    }

    /// Which requested scopes unlock which part of the vehicle. Volvo grants a scope per
    /// feature, so this is also the map that turns "invalid_scope on a narrower tier" into a
    /// per-domain answer instead of one account-wide boolean.
    static let domainScopes: [DomainScopes] = [
        .init(domain: .telemetry, scopes: [
            "openid", "conve:vehicle_relation", "conve:doors_status",
            "conve:windows_status", "conve:tyre_status", "conve:diagnostics_workshop",
            "conve:diagnostics_engine_status", "conve:fuel_status", "conve:engine_status",
            "conve:brake_status", "conve:warnings", "conve:odometer_status",
            "conve:trip_statistics"
        ]),
        .init(domain: .energy, scopes: [
            "energy:capability:read", "energy:state:read", "conve:battery_charge_level"
        ]),
        .init(domain: .availability, scopes: ["conve:command_accessibility"]),
        .init(domain: .commands, scopes: ["conve:commands"]),
        .init(domain: .climate, scopes: ["conve:climatization_start_stop"]),
        .init(domain: .locks, scopes: ["conve:lock", "conve:unlock"]),
        .init(domain: .engine, scopes: ["conve:engine_start_stop"]),
        .init(domain: .honkFlash, scopes: ["conve:honk_flash"]),
        .init(domain: .location, scopes: ["location:read"])
    ]

    /// A token response lists granted scopes space-separated. Blank and absent both mean the
    /// provider did not state a grant, which stays distinguishable from "granted nothing".
    static func parseGrantedScopes(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        let scopes = raw.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return scopes.isEmpty ? nil : Array(Set(scopes)).sorted()
    }

    static func grants(
        requestedScopes: [String],
        grantedScopes: [String]?,
        tier: VolvoAPI.ScopeTier?
    ) -> [ProviderScopeGrant] {
        let requested = Set(requestedScopes)
        let granted = grantedScopes.map(Set.init)
        return domainScopes.map { mapping in
            let applicable = mapping.scopes.filter { requested.contains($0) }
            let grantedHere = granted.map { mapping.scopes.filter($0.contains) } ?? []
            let state: ProviderScopeGrantState
            if let granted {
                if applicable.isEmpty && grantedHere.isEmpty {
                    // The token states what it granted but this process no longer holds the
                    // request (a cold restore after a reset). "Not requested" would claim a
                    // fact nobody observed.
                    state = requested.isEmpty ? .unknown : .notRequested
                } else if grantedHere.isEmpty {
                    state = .notGranted
                } else if applicable.allSatisfy(granted.contains) {
                    state = .granted
                } else {
                    state = .partial
                }
            } else if applicable.isEmpty {
                state = .notRequested
            } else {
                // The scopes were requested but this authorization did not say what it granted.
                // A narrowed tier is evidence that restricted scopes were refused, but it is
                // carried by the requested list already; no claim is made beyond that.
                _ = tier
                state = .unknown
            }
            return ProviderScopeGrant(
                domain: mapping.domain,
                scopes: applicable.isEmpty ? Array(mapping.scopes.prefix(2)) : applicable,
                state: state
            )
        }
    }

    // MARK: - Degraded readings

    /// One wrapped field the provider answered with a status instead of a value. Fields in the
    /// `OK` state are not recorded: a healthy reading is not a degradation.
    static func readings<Value: Decodable & Sendable>(
        _ field: VolvoField<Value>?,
        key: String,
        label: String,
        feature: AppFeature
    ) -> ProviderReadingStatus? {
        guard let field else { return nil }
        let status = field.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = field.unavailableReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHealthy = status?.uppercased() == "OK"
        guard !isHealthy, status?.isEmpty == false || reason?.isEmpty == false else { return nil }
        return ProviderReadingStatus(
            feature: feature,
            field: key,
            label: label,
            status: status,
            reason: reason
        )
    }

    /// Every wrapped Volvo field in one telemetry sweep that did not answer with a value,
    /// with the field's user-facing name and the feature it feeds. A field whose status is
    /// `OK` but which carries an explicit `unavailableReason` is still recorded: that is the
    /// provider naming a cause for a missing value.
    static func degradedReadings(
        energy: VolvoEnergyStateDTO?,
        availability: VolvoCommandAccessibilityDTO?,
        doors: VolvoDoorsDTO?,
        windows: VolvoWindowsDTO?,
        odometer: VolvoOdometerDTO?
    ) -> [ProviderReadingStatus] {
        var readings: [ProviderReadingStatus] = []
        func add(_ reading: ProviderReadingStatus?) {
            guard let reading else { return }
            readings.append(reading)
        }

        add(Self.readings(energy?.batteryChargeLevel, key: "batteryChargeLevel",
                          label: L10n.text("Battery charge level"), feature: .chargingDetails))
        add(Self.readings(energy?.electricRange, key: "electricRange",
                          label: L10n.text("Electric range"), feature: .chargingDetails))
        add(Self.readings(energy?.chargingSystemStatus, key: "chargingSystemStatus",
                          label: L10n.text("Charging system status"), feature: .chargingDetails))
        add(Self.readings(energy?.chargerConnectionStatus, key: "chargerConnectionStatus",
                          label: L10n.text("Charger connection status"), feature: .chargingDetails))
        add(Self.readings(energy?.chargingPower, key: "chargingPower",
                          label: L10n.text("Charging power"), feature: .chargingDetails))
        add(Self.readings(energy?.chargingCurrentLimit, key: "chargingCurrentLimit",
                          label: L10n.text("Charging current limit"), feature: .chargingDetails))
        add(Self.readings(energy?.targetBatteryChargeLevel, key: "targetBatteryChargeLevel",
                          label: L10n.text("Charge target"), feature: .chargingDetails))
        add(Self.readings(
            energy?.estimatedChargingTimeToTargetBatteryChargeLevel,
            key: "estimatedChargingTimeToTargetBatteryChargeLevel",
            label: L10n.text("Estimated charging time to target"),
            feature: .chargingDetails))
        add(Self.readings(energy?.chargingType, key: "chargingType",
                          label: L10n.text("Charging type"), feature: .chargingDetails))
        add(Self.readings(energy?.chargerPowerStatus, key: "chargerPowerStatus",
                          label: L10n.text("Charger power status"), feature: .chargingDetails))

        add(Self.readings(availability?.availabilityStatus, key: "availabilityStatus",
                          label: L10n.text("Availability"), feature: .vehicleAvailability))
        add(Self.readings(doors?.centralLock, key: "centralLock",
                          label: L10n.text("Locks"), feature: .exteriorStatus))
        add(Self.readings(windows?.frontLeftWindow, key: "frontLeftWindow",
                          label: L10n.text("Windows"), feature: .exteriorStatus))
        add(Self.readings(odometer?.odometer, key: "odometer",
                          label: L10n.text("Odometer"), feature: .vehicleHealth))
        return readings
    }

    /// The report a Volvo refresh attaches to the snapshot. `recordedAt` is the time the grant
    /// evidence was recorded, not the refresh: the scope list only changes when a token is
    /// granted, and a refresh that re-used the token did not learn anything new about it.
    static func report(
        requestedScopes: [String],
        grantedScopes: [String]?,
        tier: VolvoAPI.ScopeTier?,
        recordedAt: Date?,
        degradedReadings: [ProviderReadingStatus]
    ) -> ProviderCapabilityReport {
        ProviderCapabilityReport(
            providerName: VehicleBrand.volvo.displayName,
            channel: .volvo,
            recordedAt: recordedAt,
            requestedScopes: requestedScopes,
            grantedScopes: grantedScopes,
            grants: grants(requestedScopes: requestedScopes, grantedScopes: grantedScopes, tier: tier),
            degradedReadings: degradedReadings,
            supportedDomains: ProviderDomainSupportMap.domains(for: .volvo),
            servedByFallback: false
        )
    }
}
