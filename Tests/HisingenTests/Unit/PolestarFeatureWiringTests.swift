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
    private func makePreferences(_ label: String) -> ScopedPreferences {
        ScopedPreferences(label: "polestar-features-\(label)")
    }

    // MARK: - F1: Factory passport

    @Test @MainActor func factoryPassportCSVCoversAllIdentityFields() throws {
        let prefs = makePreferences("passport").store
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
        let prefs = makePreferences("passport-esc").store
        let state = makeState(externalColour: "Space Black, \"Limited\"")
        let csv = InfoTabView.factoryPassportCSV(state: state, preferences: prefs)
        let paintLine = csv.split(separator: "\n").first { $0.contains("Exterior Paint") }
        let line = try #require(paintLine)
        #expect(line.contains("\"Space Black, \"\"Limited\"\"\""))
    }

    @Test @MainActor func factoryPassportCSVOmitsUnknownFieldsInsteadOfPlaceholders() throws {
        let prefs = makePreferences("passport-sparse").store
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
        let prefs = makePreferences("passport-content").store
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
        charging += Protobuf.intField(6, 1)      // Charging has no tag 6
        var car = Data()
        car += Protobuf.stringField(1, "VIN-RAW")
        car += Protobuf.intField(21, 1)          // reports_avg_fuel_consumption, not decoded
        car += Protobuf.messageField(35, charging)
        let caps = try #require(PolestarGRPC.parseMyCars(
            Protobuf.messageField(1, Protobuf.messageField(1, car)), vin: "VIN-RAW"))
        let raw = try #require(caps.unknownWireFields)
        #expect(raw.map { "\($0.subfield ?? 0).\($0.field)" } == ["0.21", "35.6"])
    }

    // MARK: - Enum-driven capability wiring

    /// Builds a `GetMyCars` response whose Car message carries one nested capability block.
    private func myCars(car: Data, vin: String) -> VehicleOTACapabilities? {
        PolestarGRPC.parseMyCars(
            Protobuf.messageField(1, Protobuf.messageField(1,
                Protobuf.stringField(1, vin) + car)), vin: vin)
    }

    @Test func myCarsLockTypeGatesLocksAndReducedGuard() throws {
        func capabilities(lockType: Int) -> VehicleOTACapabilities? {
            myCars(car: Protobuf.messageField(36, Protobuf.intField(1, lockType)), vin: "VIN-LOCK")
        }
        let reducedGuard = try #require(capabilities(lockType: 3))
        #expect(reducedGuard.advertisedCapabilities?[.locks] == true)
        #expect(reducedGuard.advertisedCapabilities?[.reducedGuardLock] == true)

        let plainLock = try #require(capabilities(lockType: 2))
        #expect(plainLock.advertisedCapabilities?[.locks] == true)
        #expect(plainLock.advertisedCapabilities?[.reducedGuardLock] == false)

        let noLock = try #require(capabilities(lockType: 1))
        #expect(noLock.advertisedCapabilities?[.locks] == false)

        // The Polestar 2 reference table hides reduced-guard locking; the car's own answer wins.
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2", vin: "YSM00000000000228",
                                               advertised: reducedGuard.advertisedCapabilities ?? [:])
        #expect(profile.support(for: .reducedGuardLock) == .supported)
        #expect(profile.permits(.reducedGuardLock))
    }

    @Test func myCarsChargeTimerTypeGatesSchedulesAndLocations() throws {
        func capabilities(timerType: Int) -> VehicleOTACapabilities? {
            myCars(car: Protobuf.messageField(35, Protobuf.intField(10, timerType)), vin: "VIN-TIMER")
        }
        let none = try #require(capabilities(timerType: 1))
        #expect(none.advertisedCapabilities?[.chargingSchedule] == false)

        let global = try #require(capabilities(timerType: 2))
        #expect(global.advertisedCapabilities?[.chargeLocations] == nil)

        let locationBased = try #require(capabilities(timerType: 3))
        #expect(locationBased.advertisedCapabilities?[.chargeLocations] == true)
    }

    @Test func myCarsClimatizationTypeGatesClimateStart() throws {
        func capabilities(type: Int) -> VehicleOTACapabilities? {
            myCars(car: Protobuf.messageField(37, Protobuf.intField(1, type)), vin: "VIN-CLIMATE")
        }
        let absent = try #require(capabilities(type: 1))
        #expect(absent.advertisedCapabilities?[.climateStartStop] == false)
        #expect(try #require(capabilities(type: 2)).advertisedCapabilities?[.climateStartStop] == true)
        #expect(try #require(capabilities(type: 3)).advertisedCapabilities?[.climateStartStop] == true)
    }

    @Test func myCarsUnlockTypeGatesRemoteUnlockAndTrunk() throws {
        func capabilities(unlockType: Int) -> VehicleOTACapabilities? {
            myCars(car: Protobuf.messageField(36, Protobuf.intField(2, unlockType)), vin: "VIN-UNLOCK")
        }
        let noUnlock = try #require(capabilities(unlockType: 1))
        #expect(noUnlock.advertisedCapabilities?[.remoteUnlock] == false)

        let trunkOnly = try #require(capabilities(unlockType: 2))
        #expect(trunkOnly.advertisedCapabilities?[.remoteUnlock] == false)
        #expect(trunkOnly.advertisedCapabilities?[.trunk] == true)
        // The tailgate still unlocks on a trunk-only car, so that control has to stay offered.
        #expect(trunkOnly.supportsTrunkUnlock)

        let direct = try #require(capabilities(unlockType: 3))
        #expect(direct.advertisedCapabilities?[.remoteUnlock] == true)

        // The lock and unlock commands ask different questions of the same car.
        #expect(RemoteCommand.lock.requiredCapability == .locks)
        #expect(RemoteCommand.unlock.requiredCapability == .remoteUnlock)
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2", vin: "YSM00000000000228",
                                               advertised: trunkOnly.advertisedCapabilities ?? [:])
        #expect(profile.permits(.locks))
        #expect(!profile.permits(.remoteUnlock))
    }

    @Test func myCarsPlugAndChargeNeedsTheIdentifierPair() throws {
        let flagOnly = try #require(myCars(car: Protobuf.messageField(35, Protobuf.intField(29, 1)),
                                           vin: "VIN-PNC"))
        #expect(flagOnly.supportsPlugAndCharge)
        #expect(flagOnly.plugAndChargeIdentifier == nil)

        let paired = try #require(myCars(car: Protobuf.messageField(
            35, Protobuf.intField(29, 1) + Protobuf.stringField(20, "PCID-1")), vin: "VIN-PNC"))
        #expect(paired.plugAndChargeIdentifier == "PCID-1")
    }

    @Test func myCarsClimatizationTypeAndRuntimeReachTheCard() throws {
        let both = try #require(myCars(car: Protobuf.messageField(
            37, Protobuf.intField(1, 3) + Protobuf.intField(3, 30)), vin: "VIN-CLIMATE-TYPE"))
        #expect(both.climatizationType == .heatingAndCooling)
        #expect(both.climatizationMaximumRuntimeMinutes == 30)

        let heating = try #require(myCars(car: Protobuf.messageField(
            37, Protobuf.intField(1, 2)), vin: "VIN-CLIMATE-TYPE"))
        #expect(heating.climatizationType == .heating)
        #expect(heating.climatizationMaximumRuntimeMinutes == nil)
    }

    @Test func myCarsPerLocationLimitsReachTheControlSettings() throws {
        let caps = try #require(myCars(car: Protobuf.messageField(35,
            Protobuf.intField(13, 2) + Protobuf.intField(17, 1) + Protobuf.intField(18, 4)),
            vin: "VIN-LIMITS"))
        let settings = try #require(caps.controlSettings)
        #expect(settings.timersPerLocationMaximum == 2)
        #expect(settings.departureTimesPerLocationMaximum == 4)
        #expect(settings.locationDepartureTimes == true)
    }

    @Test func visualIdentityNamesTheVerifiedGroupsOnly() throws {
        // The captured 16-group string: type at 1, grille variant at 12, model year at 16.
        let captured = ["534", "110U", "1401", "CB04", "CJ06", "C101", "EV05", "TP00",
                        "NP02", "105A", "6A0D", "GR04", "R159", "R00C", "LR02", "2023"]
        var equipment = VehicleEquipment()
        equipment.contentCodes = captured
        let entries = equipment.contentCodeEntries
        #expect(entries.count == 16)
        #expect(entries[0].label == "Vehicle Type")
        #expect(entries[11].label == "Grille Variant")
        #expect(entries[15].label == "Model Year")
        // Everything between the three verified groups stays positional instead of guessed.
        #expect(entries[1].label == nil)
        #expect(entries[1].code == "110U")
        #expect(entries[12].label == nil)

        // A different platform's string must not inherit a name from the value's position alone.
        equipment.contentCodes = ["P3", "110U", "1401", "CB04", "CJ06", "C101", "EV05", "TP00",
                                  "NP02", "105A", "6A0D", "1401", "R159", "R00C", "LR02", "ABC"]
        let guarded = equipment.contentCodeEntries
        #expect(guarded[0].label == nil)
        #expect(guarded[11].label == nil)
        #expect(guarded[15].label == nil)

        // A truncated string still yields only the groups it has.
        equipment.contentCodes = ["534", "110U", "GR04", "2023"]
        let short = equipment.contentCodeEntries
        #expect(short.count == 4)
        #expect(short[0].label == "Vehicle Type")
        #expect(short[2].label == nil && short[3].label == nil)
    }

    @Test func equipmentShowsGrossVehicleWeight() throws {
        let caps = try #require(myCars(car: Protobuf.floatField(44, 2600), vin: "VIN-GVWR"))
        let equipment = try #require(caps.equipment)
        #expect(equipment.grossVehicleWeightRatingKg == 2600)
        let row = try #require(equipment.details.first { $0.title == "Gross Vehicle Weight" })
        #expect(row.value == "2600 kg")
    }

    // MARK: - F5: Owner gate

    @Test func ownerGateBlocksWhenExplicitlyFalse() {
        let state = makeState(userIsOwner: false)
        let gate = CapabilityGate()
        let availability = gate.availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .polestarID),
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
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .polestarID),
            enabledFeatures: [.remoteLocks], commandInProgress: false
        )
        #expect(availability != .notVehicleOwner)
    }

    @Test func ownerGateAllowsExplicitOwner() {
        let state = makeState(userIsOwner: true)
        let gate = CapabilityGate()
        let availability = gate.availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .polestarID),
            enabledFeatures: [.remoteLocks], commandInProgress: false
        )
        #expect(availability != .notVehicleOwner)
    }

    @Test func ownerGateRunsBeforeFreshnessGate() {
        // An owner-explicit-false state with a stale snapshot must report the ownership
        // reason, not the refresh reason – ownership is a policy fact, not a timing one.
        var state = makeState(userIsOwner: false)
        state.freshness.fetchedAt = Date().addingTimeInterval(-60 * 60)
        let gate = CapabilityGate()
        let availability = gate.availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .polestarID),
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
