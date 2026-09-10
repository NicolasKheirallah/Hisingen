import Foundation
import Testing
@testable import Hisingen

/// Wiring tests for the feature set added on top of the decoded Polestar surface: factory
/// passport export, the owner command gate, the pre-clean toggle availability, and the cabin
/// thermal matrix output.
struct PolestarFeatureWiringTests {
    private func makeState(
        vin: String = "YSM00000000000228",
        packages: [String] = ["Pilot Lite"],
        userIsOwner: Bool? = nil,
        externalColour: String? = "Thunder",
        upholstery: String? = "Weave Tech",
        wheels: String? = "20\" Performance",
        registrationNo: String? = "ABC 123"
    ) -> VehicleState {
        var state = VehicleState(
            batteryPercentage: 75, rangeKm: 270, chargingState: .unknown("UNSPECIFIED"),
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: nil,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .unknown, availability: .available,
            modelName: "Polestar 2", modelYear: "2023", registrationNo: registrationNo,
            vin: vin, ownerFirstName: nil, odometerKm: nil, imageData: nil, fetchedAt: Date(),
            vehicleReportedAt: nil, dataWarnings: []
        )
        state.identity.externalColour = externalColour
        state.identity.upholstery = upholstery
        state.identity.wheels = wheels
        state.identity.packages = packages
        state.identity.internalVehicleIdentifier = "iv-1"
        state.identity.pno34 = "PNO34-XX"
        state.identity.structureWeek = "202326"
        state.identity.accountMarket = "SE"
        if let userIsOwner {
            state.otaCapabilities = VehicleOTACapabilities(userIsOwner: userIsOwner)
        }
        return state
    }

    @MainActor
    private func makePreferences(_ label: String) -> PreferencesStore {
        let suite = "polestar-features-\(label)-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = PreferencesStore(defaults: defaults, keychain: .app)
        return store
    }

    // MARK: - F1: Factory passport

    @Test @MainActor func factoryPassportCSVCoversAllIdentityFields() throws {
        let prefs = makePreferences("passport")
        let state = makeState()
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        for header in ["VIN", "Nickname", "Model", "Registration No", "Internal Vehicle ID",
                       "Factory Spec (PNO34)", "Factory Build Week", "Market",
                       "Exterior Paint", "Upholstery", "Wheels", "Factory Packages"] {
            #expect(csv.contains(header), "missing header: \(header)")
        }
        #expect(csv.contains("YSM00000000000228"))
        #expect(csv.contains("Polestar 2 2023"))
        #expect(csv.contains("Weave Tech"))
        // `formattedBuildWeek` renders the raw structure week ("202326") as "2023 · W26".
        #expect(csv.contains("W26"))
    }

    @Test @MainActor func factoryPassportCSVEscapesCommasAndQuotes() throws {
        let prefs = makePreferences("passport-esc")
        let state = makeState(packages: [], externalColour: "Space Black, \"Limited\"")
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        let paintLine = csv.split(separator: "\n").first { $0.contains("Exterior Paint") }
        let line = try #require(paintLine)
        #expect(line.contains("\"Space Black, \"\"Limited\"\"\""))
    }

    @Test @MainActor func factoryPassportCSVOmitsUnknownFieldsInsteadOfPlaceholders() throws {
        let prefs = makePreferences("passport-sparse")
        let state = makeState(externalColour: nil, upholstery: nil, wheels: nil, registrationNo: nil)
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        let paintLine = csv.split(separator: "\n").first { $0.contains("Exterior Paint") }
        let line = try #require(paintLine)
        #expect(line.hasSuffix("Exterior Paint,"))
    }

    @Test @MainActor func factoryPassportCSVListsEachPackageAsItsOwnRow() throws {
        let prefs = makePreferences("passport-pkgs")
        let state = makeState(packages: ["Pilot Lite", "Climate Pack"])
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        #expect(csv.contains("Package 1,Pilot Lite"))
        #expect(csv.contains("Package 2,Climate Pack"))
    }

    // MARK: - F5: Owner gate

    @Test func ownerGateBlocksWhenExplicitlyFalse() {
        let state = makeState(userIsOwner: false)
        let gate = CapabilityGate()
        let availability = gate.availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar),
            enabledFeatures: [.remoteLocks], commandInProgress: false
        )
        #expect(availability == .notVehicleOwner)
        #expect(availability.shortReason?.isEmpty == false)
    }

    @Test func ownerGateAllowsUnknownOwnership() {
        let state = makeState(userIsOwner: nil)
        let gate = CapabilityGate()
        #expect(state.accountOwnsVehicle == nil)
        let availability = gate.availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar),
            enabledFeatures: [.remoteLocks], commandInProgress: false
        )
        #expect(availability != .notVehicleOwner)
    }

    @Test func ownerGateAllowsExplicitOwner() {
        let state = makeState(userIsOwner: true)
        let gate = CapabilityGate()
        let availability = gate.availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar),
            enabledFeatures: [.remoteLocks], commandInProgress: false
        )
        #expect(availability != .notVehicleOwner)
    }

    @Test func ownerGateRunsBeforeFreshnessGate() {
        // An owner-explicit-false state with a stale snapshot must report the ownership
        // reason, not the refresh reason — ownership is a policy fact, not a timing one.
        var state = makeState(userIsOwner: false)
        state.freshness.fetchedAt = Date().addingTimeInterval(-60 * 60)
        let gate = CapabilityGate()
        let availability = gate.availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar),
            enabledFeatures: [.remoteLocks], commandInProgress: false
        )
        #expect(availability == .notVehicleOwner)
    }

    // MARK: - F3: Pre-clean toggle availability

    @Test func preCleanToggleAvailabilityFollowsReportedState() {
        let reported = VehicleAirQuality(cleaningState: .off)
        #expect(reported.canTogglePreCleaning)

        let unknown = VehicleAirQuality(cleaningState: .unknown)
        #expect(unknown.canTogglePreCleaning == false)
    }

    // MARK: - F4: Thermal matrix

    @MainActor
    @Test func thermalMatrixAccessibilitySummaryListsActiveHeaters() {
        let matrix = CabinThermalMatrix(
            driverSeatLevel: 2, passengerSeatLevel: 0, steeringWheelLevel: 1,
            interiorTemperatureCelsius: 18.0, requestedTemperatureCelsius: 22.0,
            activity: .heating
        )
        let summary = matrix.accessibilitySummary
        #expect(summary.contains("Driver Seat"))
        #expect(summary.contains("level 1"))
        #expect(summary.contains("Heating"))
        #expect(summary.contains("18.0") || summary.contains("18"))
        // Inactive heater contributes no level row.
        #expect(!summary.contains("Passenger Seat: level"))
    }

    @MainActor
    @Test func thermalMatrixIdleHidesLevelRows() {
        let matrix = CabinThermalMatrix(
            driverSeatLevel: nil, passengerSeatLevel: nil, steeringWheelLevel: nil,
            interiorTemperatureCelsius: nil, requestedTemperatureCelsius: nil,
            activity: .idle
        )
        let summary = matrix.accessibilitySummary
        #expect(!summary.contains("level"))
        #expect(summary.contains("Idle"))
    }
}
