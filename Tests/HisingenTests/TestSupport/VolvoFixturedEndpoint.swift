import Foundation
@testable import Hisingen

/// One Volvo GET resource the adapter actually calls, with the saved sanitized fixture that
/// proves its decoding and the projection the fixture test asserts.
///
/// The live sweep iterates this same case list, so the endpoint inventory, the fixtures and the
/// opt-in network probe cannot drift apart. Values in the fixtures are fake; the VINs use the
/// `YV1FIXTURE` prefix that the fixture-integrity checks already accept.
enum VolvoFixturedEndpoint: String, CaseIterable, Sendable {
    case vehiclesList
    case vehicleDetails
    case doors
    case windows
    case tyres
    case fuel
    case energyState
    case energyCapabilities
    case diagnostics
    case engineDiagnostics
    case brakes
    case warnings
    case odometer
    case statistics
    case location
    case engineStatus
    case commandAccessibility
    case commands
    case vocSubscription

    var title: String {
        switch self {
        case .vehiclesList: return "Vehicles discovery"
        case .vehicleDetails: return "Vehicle details"
        case .doors: return "Doors & central lock"
        case .windows: return "Windows"
        case .tyres: return "Tyres & iTPMS"
        case .fuel: return "Fuel"
        case .energyState: return "Energy state"
        case .energyCapabilities: return "Energy capabilities"
        case .diagnostics: return "Diagnostics & service"
        case .engineDiagnostics: return "Engine diagnostics"
        case .brakes: return "Brakes"
        case .warnings: return "Warnings & lighting"
        case .odometer: return "Odometer"
        case .statistics: return "Trip statistics"
        case .location: return "Parking location"
        case .engineStatus: return "Engine status"
        case .commandAccessibility: return "Command accessibility"
        case .commands: return "Advertised commands"
        case .vocSubscription: return "VOC subscription"
        }
    }

    var fixtureName: String {
        switch self {
        case .vehiclesList: return "volvo-vehicles-list"
        case .vehicleDetails: return "volvo-vehicle-details-bev"
        case .doors: return "volvo-doors"
        case .windows: return "volvo-windows"
        case .tyres: return "volvo-tyres"
        case .fuel: return "volvo-fuel"
        case .energyState: return "volvo-energy-state"
        case .energyCapabilities: return "volvo-energy-capabilities"
        case .diagnostics: return "volvo-diagnostics"
        case .engineDiagnostics: return "volvo-engine-diagnostics"
        case .brakes: return "volvo-brakes"
        case .warnings: return "volvo-warnings"
        case .odometer: return "volvo-odometer"
        case .statistics: return "volvo-statistics"
        case .location: return "volvo-location"
        case .engineStatus: return "volvo-engine-status"
        case .commandAccessibility: return "volvo-command-accessibility"
        case .commands: return "volvo-commands"
        case .vocSubscription: return "volvo-voc-subscription"
        }
    }

    var pathTemplate: String {
        switch self {
        case .vehiclesList: return "/connected-vehicle/v2/vehicles"
        case .vehicleDetails: return "/connected-vehicle/v2/vehicles/{vin}"
        case .doors: return "/connected-vehicle/v2/vehicles/{vin}/doors"
        case .windows: return "/connected-vehicle/v2/vehicles/{vin}/windows"
        case .tyres: return "/connected-vehicle/v2/vehicles/{vin}/tyres"
        case .fuel: return "/connected-vehicle/v2/vehicles/{vin}/fuel"
        case .energyState: return "/energy/v2/vehicles/{vin}/state"
        case .energyCapabilities: return "/energy/v2/vehicles/{vin}/capabilities"
        case .diagnostics: return "/connected-vehicle/v2/vehicles/{vin}/diagnostics"
        case .engineDiagnostics: return "/connected-vehicle/v2/vehicles/{vin}/engine"
        case .brakes: return "/connected-vehicle/v2/vehicles/{vin}/brakes"
        case .warnings: return "/connected-vehicle/v2/vehicles/{vin}/warnings"
        case .odometer: return "/connected-vehicle/v2/vehicles/{vin}/odometer"
        case .statistics: return "/connected-vehicle/v2/vehicles/{vin}/statistics"
        case .location: return "/location/v1/vehicles/{vin}/location"
        case .engineStatus: return "/connected-vehicle/v2/vehicles/{vin}/engine-status"
        case .commandAccessibility: return "/connected-vehicle/v2/vehicles/{vin}/command-accessibility"
        case .commands: return "/connected-vehicle/v2/vehicles/{vin}/commands"
        case .vocSubscription: return "/energy/v2/vehicles/{vin}/voc-subscription"
        }
    }

    func path(vin: String) -> String {
        pathTemplate.replacingOccurrences(of: "{vin}", with: vin)
    }

    /// The projection the fixture proves. It names the decoded values a fixture test asserts,
    /// so a payload that stops mapping to the app's model fails instead of merely parsing.
    var expectedProjection: String {
        switch self {
        case .vehiclesList: return "YV1FIXTURE0000001,YV1FIXTURE0000002"
        case .vehicleDetails: return "EX30|2024|ELECTRIC"
        case .doors: return "locked"
        case .windows: return "CLOSED"
        case .tyres: return "0,1,3,4"
        case .fuel: return "42.0"
        case .energyState: return "68.0|210|CHARGING"
        case .energyCapabilities: return "chargingPower:true|targetBatteryLevel:false"
        case .diagnostics: return "Oil|CALENDAR_TIME"
        case .engineDiagnostics: return "Oil|1200"
        case .brakes: return "OK|LOW|ENGAGED"
        case .warnings: return "Right brake light: BRAKE_LIGHT_FAILURE"
        case .odometer: return "42317"
        case .statistics: return "500.0"
        case .location: return "3|180"
        case .engineStatus: return "false"
        case .commandAccessibility:
            return "false|" + L10n.text("Vehicle is in power-saving mode")
        case .commands: return "lock,unlock,climatization-start,honk-flash"
        case .vocSubscription: return "true"
        }
    }

    // MARK: - Fixture side

    func fixtureData() throws -> Data {
        guard let url = Bundle.module.url(forResource: fixtureName, withExtension: "json") else {
            throw FixtureError.missing(fixtureName)
        }
        return try Data(contentsOf: url)
    }

    /// Decode the saved fixture through the same DTOs the adapter uses and return the
    /// projection. The VOC subscription response is a root object, not the usual `data`
    /// envelope, so it is the one case decoded directly.
    func decodeFixture() throws -> String {
        let data = try fixtureData()
        switch self {
        case .vocSubscription:
            let dto = try JSONDecoder.volvo.decode(VolvoVOCSubscriptionDTO.self, from: data)
            return String(dto.hasPremiumSubscription == true)
        case .vehiclesList:
            let list = try decodeEnvelope([VolvoVehicleSummaryDTO].self, data)
            return list.map(\.vin).joined(separator: ",")
        case .vehicleDetails:
            let details = try decodeEnvelope(VolvoVehicleDetailsDTO.self, data)
            return [
                details.descriptions?.model ?? "-",
                details.modelYear.map(String.init) ?? "-",
                details.fuelType ?? "-"
            ].joined(separator: "|")
        case .doors:
            let doors = try decodeEnvelope(VolvoDoorsDTO.self, data)
            return doors.isLocked == true ? "locked" : "unlocked"
        case .windows:
            let windows = try decodeEnvelope(VolvoWindowsDTO.self, data)
            return windows.frontLeftWindow?.value ?? "-"
        case .tyres:
            let tyres = try decodeEnvelope(VolvoTyresDTO.self, data)
            return tyres.readings.map { String($0.warning.rawValue) }.joined(separator: ",")
        case .fuel:
            let fuel = try decodeEnvelope(VolvoFuelDTO.self, data)
            return String(fuel.liters ?? -1)
        case .energyState:
            let energy = try decodeEnvelope(VolvoEnergyStateDTO.self, data)
            return [
                String(energy.batteryChargeLevel?.value ?? -1),
                energy.rangeKm.map(String.init) ?? "-",
                energy.chargingStateValue ?? "-"
            ].joined(separator: "|")
        case .energyCapabilities:
            let caps = try decodeEnvelope(VolvoEnergyCapabilitiesDTO.self, data)
            return "chargingPower:\(caps.chargingPower?.isSupported == true)"
                + "|targetBatteryLevel:\(caps.targetBatteryChargeLevel?.isSupported == true)"
        case .diagnostics:
            let diagnostics = try decodeEnvelope(VolvoDiagnosticsDTO.self, data)
            return (diagnostics.fluidWarnings + [diagnostics.serviceTrigger?.value ?? "-"])
                .joined(separator: "|")
        case .engineDiagnostics:
            let diagnostics = try decodeEnvelope(VolvoDiagnosticsDTO.self, data)
            return (diagnostics.fluidWarnings + [String(diagnostics.engineHoursToService?.value ?? -1)])
                .joined(separator: "|")
        case .brakes:
            let brakes = try decodeEnvelope(VolvoBrakesDTO.self, data)
            return [
                brakes.frontBrakePadStatus?.value ?? "-",
                brakes.rearBrakePadStatus?.value ?? "-",
                brakes.parkingBrakeStatus?.value ?? "-"
            ].joined(separator: "|")
        case .warnings:
            let warnings = try decodeEnvelope(VolvoWarningsDTO.self, data)
            return warnings.activeWarnings.first ?? "-"
        case .odometer:
            let odometer = try decodeEnvelope(VolvoOdometerDTO.self, data)
            return odometer.odometerKm.map(String.init) ?? "-"
        case .statistics:
            let statistics = try decodeEnvelope(VolvoStatisticsDTO.self, data)
            return String(statistics.tripMeterManualKm ?? -1)
        case .location:
            let location = try decodeEnvelope(VolvoLocationDTO.self, data)
            return [
                String(location.geometry?.coordinates?.count ?? 0),
                location.properties?.heading ?? "-"
            ].joined(separator: "|")
        case .engineStatus:
            let engine = try decodeEnvelope(VolvoEngineStatusDTO.self, data)
            return String(engine.isRunning == true)
        case .commandAccessibility:
            let accessibility = try decodeEnvelope(VolvoCommandAccessibilityDTO.self, data)
            return "\(accessibility.isAvailable)|\(accessibility.reason ?? "-")"
        case .commands:
            let commands = try decodeEnvelope([VolvoCommandDTO].self, data)
            return commands.compactMap(\.normalizedName).joined(separator: ",")
        }
    }

    private func decodeEnvelope<Payload: Decodable & Sendable>(
        _ type: Payload.Type, _ data: Data
    ) throws -> Payload {
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<Payload>.self, from: data)
        guard let payload = envelope.data else { throw FixtureError.emptyEnvelope(fixtureName) }
        return payload
    }

    // MARK: - Live side

    /// Read the endpoint through the production adapter and return the same projection the
    /// fixture test asserts. The live sweep uses this so a shape change on Volvo's side is
    /// caught by the same decode path, not a hand-built request.
    func fetch(using api: VolvoAPI, vin: String) async throws -> String {
        let path = path(vin: vin)
        let scope: VehicleLogScope = self == .vehiclesList ? .account : .vehicle(vin)
        switch self {
        case .vehiclesList:
            let list: [VolvoVehicleSummaryDTO] = try await api.getList(path, scope: scope)
            return list.map(\.vin).joined(separator: ",")
        case .vehicleDetails:
            let details: VolvoVehicleDetailsDTO = try await api.get(path, scope: scope)
            return [
                details.descriptions?.model ?? "-",
                details.modelYear.map(String.init) ?? "-",
                details.fuelType ?? "-"
            ].joined(separator: "|")
        case .doors:
            let doors: VolvoDoorsDTO = try await api.get(path, scope: scope)
            return doors.isLocked == true ? "locked" : "unlocked"
        case .windows:
            let windows: VolvoWindowsDTO = try await api.get(path, scope: scope)
            return windows.frontLeftWindow?.value ?? "-"
        case .tyres:
            let tyres: VolvoTyresDTO = try await api.get(path, scope: scope)
            return tyres.readings.map { String($0.warning.rawValue) }.joined(separator: ",")
        case .fuel:
            let fuel: VolvoFuelDTO = try await api.get(path, scope: scope)
            return String(fuel.liters ?? -1)
        case .energyState:
            let energy: VolvoEnergyStateDTO = try await api.get(path, scope: scope)
            return [
                String(energy.batteryChargeLevel?.value ?? -1),
                energy.rangeKm.map(String.init) ?? "-",
                energy.chargingStateValue ?? "-"
            ].joined(separator: "|")
        case .energyCapabilities:
            let caps: VolvoEnergyCapabilitiesDTO = try await api.get(path, scope: scope)
            return "chargingPower:\(caps.chargingPower?.isSupported == true)"
                + "|targetBatteryLevel:\(caps.targetBatteryChargeLevel?.isSupported == true)"
        case .diagnostics, .engineDiagnostics:
            let diagnostics: VolvoDiagnosticsDTO = try await api.get(path, scope: scope)
            if self == .diagnostics {
                return (diagnostics.fluidWarnings + [diagnostics.serviceTrigger?.value ?? "-"])
                    .joined(separator: "|")
            }
            return (diagnostics.fluidWarnings
                + [String(diagnostics.engineHoursToService?.value ?? -1)]).joined(separator: "|")
        case .brakes:
            let brakes: VolvoBrakesDTO = try await api.get(path, scope: scope)
            return [
                brakes.frontBrakePadStatus?.value ?? "-",
                brakes.rearBrakePadStatus?.value ?? "-",
                brakes.parkingBrakeStatus?.value ?? "-"
            ].joined(separator: "|")
        case .warnings:
            let warnings: VolvoWarningsDTO = try await api.get(path, scope: scope)
            return warnings.activeWarnings.first ?? "-"
        case .odometer:
            let odometer: VolvoOdometerDTO = try await api.get(path, scope: scope)
            return odometer.odometerKm.map(String.init) ?? "-"
        case .statistics:
            let statistics: VolvoStatisticsDTO = try await api.get(path, scope: scope)
            return String(statistics.tripMeterManualKm ?? -1)
        case .location:
            let location: VolvoLocationDTO = try await api.get(path, scope: scope)
            return [
                String(location.geometry?.coordinates?.count ?? 0),
                location.properties?.heading ?? "-"
            ].joined(separator: "|")
        case .engineStatus:
            let engine: VolvoEngineStatusDTO = try await api.get(path, scope: scope)
            return String(engine.isRunning == true)
        case .commandAccessibility:
            let accessibility: VolvoCommandAccessibilityDTO = try await api.get(path, scope: scope)
            return "\(accessibility.isAvailable)|\(accessibility.reason ?? "-")"
        case .commands:
            let commands: [VolvoCommandDTO] = try await api.getList(path, scope: scope)
            return commands.compactMap(\.normalizedName).joined(separator: ",")
        case .vocSubscription:
            let subscription: VolvoVOCSubscriptionDTO = try await api.get(path, scope: scope)
            return String(subscription.hasPremiumSubscription == true)
        }
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case missing(String)
    case emptyEnvelope(String)

    var description: String {
        switch self {
        case .missing(let name): return "fixture \(name).json is missing"
        case .emptyEnvelope(let name): return "fixture \(name).json has no decodable data payload"
        }
    }
}

/// The called Volvo endpoints this evidence pass deliberately leaves without a file fixture,
/// and the reason each one is exempt. Kept next to the catalog so the gap is an explicit
/// decision rather than an omission the next reader has to rediscover.
enum VolvoFixtureExemptions {
    static let entries: [(endpoint: String, reason: String)] = [
        ("POST /connected-vehicle/v2/vehicles/{vin}/commands/{name}",
         "State-changing: a live dispatch moves hardware. The response shape is covered by inline VolvoCommandResponseDTO tests for every documented invokeStatus, and a saved success payload would not make dispatching safer."),
        ("POST token revocation",
         "The revocation endpoint answers without a decoded body; its only outcome is an HTTP status recorded in the debug log."),
        ("Vehicle image GETs",
         "The image URLs return binary CDN bytes, not a JSON payload; image handling is covered by the cache tests instead."),
        ("OIDC discovery / authorize form",
         "External identity-provider documents rather than a vehicle API; the opt-in probe asserts their shape live.")
    ]
}
