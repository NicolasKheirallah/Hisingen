import Foundation
import Testing
@testable import Hisingen

/// Wiring tests for the feature set added on top of the decoded Polestar surface: factory
/// passport export, the owner command gate, the pre-clean toggle availability, and the cabin
/// thermal matrix output.
struct PolestarFeatureWiringTests {
    private func makeState(
        vin: String = "YSM00000000000228",
        userIsOwner: Bool? = nil,
        externalColour: String? = "Thunder",
        upholstery: String? = "Weave Tech",
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
                       "Exterior Paint", "Upholstery"] {
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
        let state = makeState(externalColour: "Space Black, \"Limited\"")
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        let paintLine = csv.split(separator: "\n").first { $0.contains("Exterior Paint") }
        let line = try #require(paintLine)
        #expect(line.contains("\"Space Black, \"\"Limited\"\"\""))
    }

    @Test @MainActor func factoryPassportCSVOmitsUnknownFieldsInsteadOfPlaceholders() throws {
        let prefs = makePreferences("passport-sparse")
        let state = makeState(externalColour: nil, upholstery: nil, registrationNo: nil)
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        let paintLine = csv.split(separator: "\n").first { $0.contains("Exterior Paint") }
        let line = try #require(paintLine)
        #expect(line.hasSuffix("Exterior Paint,"))
    }

    // MARK: - Factory content codes + retained raw fields

    @Test func equipmentDetailsExposeContentCodesOnlyWhenPresent() {
        var equipment = VehicleEquipment()
        #expect(!equipment.details.contains { $0.title == "Factory Content Codes" })
        equipment.contentCodes = ["534", "110U", "GR04", "2023"]
        let row = equipment.details.first { $0.title == "Factory Content Codes" }
        #expect(row?.value == "534 110U GR04 2023")
    }

    @Test @MainActor func factoryPassportIncludesFactoryContentCodes() throws {
        let prefs = makePreferences("passport-content")
        var state = makeState()
        state.otaCapabilities = VehicleOTACapabilities(userIsOwner: true)
        var equipment = VehicleEquipment()
        equipment.contentCodes = ["534", "110U", "GR04", "2023"]
        state.otaCapabilities?.equipment = equipment
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        let codeLine = try #require(csv.split(separator: "\n").first { $0.contains("Factory Content Codes") })
        #expect(codeLine.contains("534 110U GR04 2023"))
    }

    @Test func retainedRawFieldsCarryParentMessageNumbers() throws {
        var charging = Data()
        charging += Protobuf.intField(5, 1)
        var car = Data()
        car += Protobuf.stringField(1, "VIN-RAW")
        car += Protobuf.intField(20, 1)
        car += Protobuf.messageField(35, charging)
        let caps = try #require(PolestarGRPC.parseMyCars(
            Protobuf.messageField(1, Protobuf.messageField(1, car)), vin: "VIN-RAW"))
        let raw = try #require(caps.unknownWireFields)
        #expect(raw.map { "\($0.subfield ?? 0).\($0.field)" } == ["0.20", "35.5"])
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
