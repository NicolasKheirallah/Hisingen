import Foundation
import Testing
@testable import Hisingen

struct RemoteCommandTests {
    @Test
    func testStaleVehicleSnapshotDisablesCommandsUntilRefresh() {
        var state = vehicle(vin: "YSMSTALE")
        state.freshness.fetchedAt = Date().addingTimeInterval(-11 * 60)
        let availability = CapabilityGate().availability(
            for: .lock, state: state, commandCatalog: ProviderCommandCatalog(brand: .polestar),
            enabledFeatures: [.remoteLocks], commandInProgress: false)
        #expect(availability == .unavailableUntilRefresh)
    }

    @Test
    @MainActor
    func testAuthorizedCommandIsDiscardedWhenVehicleChangesBeforeExecution() async throws {
        let suiteName = "HisingenTests.command-context.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = "YSMFIRST"
        var features = FeatureSelection.default
        features.set(.remoteLocks, enabled: true)
        preferences.features = features

        let provider = CommandContextProvider()
        let context = CommandContextMock(provider: provider, vehicleState: vehicle(vin: "YSMFIRST"))
        let authorizer = DeferredCommandAuthorizer()
        let coordinator = CommandCoordinator(
            context: context, preferences: preferences, database: .inMemory(), authorizer: authorizer
        )

        // Fire-and-forget like the interactive surfaces: the coordinator awaits the
        // authorizer, and the test unblocks it below. The task handle is kept so the
        // negative assertion is deterministic (TESTS-11): awaiting `perform` guarantees the
        // post-authorization decision has been made before the count is read, so a slow
        // machine cannot let a stale command land after the assertion.
        let performTask = Task { await coordinator.perform(.lock) }
        await authorizer.waitForAuthorizationRequest()
        context.vehicleState = vehicle(vin: "YSMSECOND")
        preferences.vin = "YSMSECOND"
        authorizer.allow()
        _ = await performTask.value

        let executedCount = await provider.executedCount()
        #expect(executedCount == 0)
    }

    @Test
    @MainActor
    func testPendingAuthorizationReservesCommandLane() async throws {
        let suiteName = "HisingenTests.command-auth-reservation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = "YSMFIRST"
        var features = FeatureSelection.default
        features.set(.remoteLocks, enabled: true)
        preferences.features = features

        let provider = CommandContextProvider()
        let context = CommandContextMock(provider: provider, vehicleState: vehicle(vin: "YSMFIRST"))
        let authorizer = DeferredCommandAuthorizer()
        let coordinator = CommandCoordinator(
            context: context, preferences: preferences, database: .inMemory(), authorizer: authorizer
        )

        let first = Task { await coordinator.perform(.lock) }
        await authorizer.waitForAuthorizationRequest()
        let quickAction = await coordinator.perform(.unlock)
        if case .deferred(let reason) = quickAction {
            #expect(reason == RemoteCommandError.busy.localizedDescription)
        } else {
            Issue.record("A notification action must not enter authorization while another approval is pending")
        }
        #expect(await provider.executedCount() == 0)
        authorizer.allow()
        _ = await first.value
        #expect(await provider.executedCount() == 1)
    }

    @Test
    func testRemoteFeaturesAreDisabledByDefault() {
        #expect(FeatureSelection.default.enabled.intersection(AppFeature.remoteFeatures).isEmpty)
        #expect(RemoteCommand.unlock.feature == .remoteLocks)
        #expect(RemoteCommand.openWindows.risk == .securitySensitive)
        #expect(RemoteCommand.installOTANow.risk == .destructive)
    }

    @Test
    func testOutcomeDescriptionStatesWhatTheCommandDid() {
        #expect(RemoteCommand.lock.outcomeDescription == L10n.text("Vehicle locked"))
        #expect(RemoteCommand.unlock.outcomeDescription == L10n.text("Vehicle unlocked"))
        #expect(RemoteCommand.stopClimate.outcomeDescription == L10n.text("AC (climate) turned off"))
        #expect(RemoteCommand.startClimate(temperatureCelsius: 22, frontLeftSeat: .off,
                                       frontRightSeat: .off, rearLeftSeat: .off,
                                       rearRightSeat: .off, steeringWheel: .off).outcomeDescription == "AC turned on at 22 °C")
        #expect(RemoteCommand.setChargeTarget(80).outcomeDescription == L10n.format("Charge target set to %d%%", 80))
    }

    @Test
    func testRemoteCommandRequiresContextAndAuthentication() async {
        do {
            _ = try await PolestarAPI().executeRemoteCommand(.lock, vin: "YSMTEST")
            Issue.record("Remote commands must require selected vehicle and authenticated session")
        } catch RemoteCommandError.missingContext {

        } catch PolestarError.authenticationRequired {

        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testClimateStartWireRequest() throws {
        let data = PolestarGRPC.climateStartRequest(
            vin: "TESTVIN", temperature: 21,
            frontLeft: .level2, frontRight: .level1,
            rearLeft: .off, rearRight: .level3, steeringWheel: .off
        )
        let fields = Protobuf.fields(data)
        let envelope = try #require(fields.first { $0.number == 1 && $0.wire == 2 })
        #expect(string(envelope.data, field: 1) == "TESTVIN")
        #expect(fields.first { $0.number == 2 }?.varint == 1)
        #expect(float(fields.first { $0.number == 3 }?.data) == 21)
        #expect(fields.first { $0.number == 4 }?.varint == UInt64(HeatingLevel.level1.rawValue))
        #expect(fields.first { $0.number == 5 }?.varint == UInt64(HeatingLevel.level2.rawValue))
        #expect(fields.first { $0.number == 6 }?.varint == UInt64(HeatingLevel.level3.rawValue))
        #expect(fields.first { $0.number == 7 }?.varint == UInt64(HeatingLevel.off.rawValue))
        #expect(fields.first { $0.number == 8 }?.varint == UInt64(HeatingLevel.off.rawValue))
    }

    @Test
    func testInvocationLifecycleStatuses() throws {
        let accepted = try PolestarGRPC.parseInvocationResult(invocation(status: 1))
        let delivered = try PolestarGRPC.parseInvocationResult(invocation(status: 4))
        let completed = try PolestarGRPC.parseInvocationResult(invocation(status: 6))
        #expect(accepted.outcome == .accepted)
        #expect(delivered.outcome == .delivered)
        #expect(completed.outcome == .completed)
        var flat = Data()
        flat.append(Protobuf.stringField(1, "request-id"))
        flat.append(Protobuf.intField(3, 6))
        let flatResult = try PolestarGRPC.parseInvocationResult(flat)
        #expect(flatResult.outcome == .completed)
        do {
            _ = try PolestarGRPC.parseInvocationResult(invocation(status: 9))
            Issue.record("Expected the privacy rejection")
        } catch {
            guard case RemoteCommandError.rejected(let message) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(message != nil)
        }
    }

    @Test
    func testGlobalChargeScheduleWireRequest() throws {
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 22, startMinute: 30,
            endHour: 6, endMinute: 15, weekdays: [], isActive: true
        )
        let timer = try PolestarGRPC.globalChargeTimer(schedule)
        let fields = Protobuf.fields(timer)
        #expect(fields.first { $0.number == 3 }?.varint == 1)
        let start = try #require(fields.first { $0.number == 1 }?.data)
        let end = try #require(fields.first { $0.number == 2 }?.data)
        #expect(Protobuf.fields(start).first { $0.number == 1 }?.varint == 22)
        #expect(Protobuf.fields(start).first { $0.number == 2 }?.varint == 30)
        #expect(Protobuf.fields(end).first { $0.number == 1 }?.varint == 6)
        #expect(Protobuf.fields(end).first { $0.number == 2 }?.varint == 15)
    }

    @Test
    func testClimateTimerPreservesBackendIdentityAndWeekdays() throws {
        let schedule = VehicleSchedule(
            backendID: "timer-id", index: 2, kind: .climate,
            startHour: 7, startMinute: 45, endHour: nil, endMinute: nil,
            weekdays: [.monday, .wednesday, .friday], isActive: true
        )
        let timer = try PolestarGRPC.climateTimer(schedule)
        let fields = Protobuf.fields(timer)
        #expect(string(timer, field: 1) == "timer-id")
        #expect(fields.first { $0.number == 2 }?.varint == 2)
        #expect(fields.first { $0.number == 4 }?.varint == 1)
        #expect(fields.first { $0.number == 5 }?.varint == 1)
        #expect(fields.first { $0.number == 6 }?.data == Data([1, 3, 5]))
    }

    @Test
    func testInvalidScheduleIsRejectedBeforeNetworkUse() {
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 30, startMinute: 0,
            endHour: 6, endMinute: 0, weekdays: [], isActive: true
        )
        do {
            _ = try PolestarGRPC.globalChargeTimer(schedule)
            Issue.record("Expected invalid schedule rejection")
        } catch {
            #expect(error is RemoteCommandError)
        }
    }

    @Test
    func testHonkHornCommandProperties() {
        let honk = RemoteCommand.honkHorn
        #expect(honk.feature == .remoteHonkFlash)
        #expect(honk.requiredCapability == .honkAndFlash)
        // Audible outside the car and not retractable: reclassified from `.routine` so it is
        // confirmed like the other security-sensitive commands rather than firing on one click.
        #expect(honk.risk == .securitySensitive)
        #expect(honk.identifier == "honk-horn")
        #expect(!(honk.title.isEmpty))
    }

    @Test
    func testHonkFlashWireRequests() throws {
        let honkAndFlash = PolestarGRPC.honkFlashRequest("VIN123", action: 0)
        let honkOnly = PolestarGRPC.honkFlashRequest("VIN123", action: 1)
        let flashOnly = PolestarGRPC.honkFlashRequest("VIN123", action: 2)

        let hfFields = Protobuf.fields(honkAndFlash)
        let hoFields = Protobuf.fields(honkOnly)
        let foFields = Protobuf.fields(flashOnly)

        #expect(hfFields.first { $0.number == 2 }?.varint == 0)
        #expect(hoFields.first { $0.number == 2 }?.varint == 1)
        #expect(foFields.first { $0.number == 2 }?.varint == 2)

        // Folded from RequestConstructionTests (TESTS-13): the honk/flash envelope must
        // carry the target VIN in its inner field 1.
        let flashEnvelope = try #require(foFields.first { $0.number == 1 && $0.wire == 2 }?.data)
        #expect(string(flashEnvelope, field: 1) == "VIN123")
    }

    @Test
    @MainActor
    func testRequireBiometricsPreference() throws {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)

        store.requireBiometricsForRemoteControls = true
        #expect(store.requireBiometricsForRemoteControls)
        store.requireBiometricsForRemoteControls = false
        #expect(!(store.requireBiometricsForRemoteControls))
    }

    @Test
    func testCommandClientAuthorizationClassification() {
        let needsAuth: [RemoteCommand] = [
            .startClimate(temperatureCelsius: 21, frontLeftSeat: .off, frontRightSeat: .off,
                          rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off),
            .stopClimate, .startPreCleaning, .stopPreCleaning,
            .lock, .unlock, .unlockTrunk, .openTailgate, .closeTailgate,
            .openWindows, .closeWindows, .flashLights, .honkAndFlash, .honkHorn
        ]
        for command in needsAuth {
            #expect(command.requiresCommandClientAuthorization, "\(command.identifier) is dispatched via invocation.InvocationService and needs the command client")
        }

        let primaryTokenOnly: [RemoteCommand] = [
            .setChargeTarget(80), .setAmpLimit(16), .startChargingOverride, .stopChargingOverride,
            .setGlobalChargeTimer(VehicleSchedule(kind: .globalCharging, startHour: 22, startMinute: 0,
                                                  endHour: 6, endMinute: 0, weekdays: [], isActive: true)),
            .deleteClimateTimer(id: "t"),
            .scheduleOTA(delayMinutes: 60), .installOTANow, .cancelOTA,
            .deleteChargeLocation(id: "loc"), .startEngine(runtimeMinutes: 10), .stopEngine,
            .lockReducedGuard
        ]
        for command in primaryTokenOnly {
            #expect(!(command.requiresCommandClientAuthorization), "\(command.identifier) is accepted with the primary session token")
        }
    }

    @Test
    func testInvocationCommandRejectedWithoutCommandToken() async {
        do {
            _ = try await PolestarGRPC().executeRemoteCommand(
                .lock, vin: "YSMTEST", accessToken: "web-token", commandToken: nil
            )
            Issue.record("An invocation command must be rejected before dispatch without a command-client token")
        } catch RemoteCommandError.rejected(let message) {
            #expect(message != nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func testHasPolestarCommandAuthorizationReflectsKeychain() throws {
        let service = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? keychain.deleteCommandSessionToken()
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PreferencesStore(defaults: defaults, keychain: keychain)

        #expect(!(store.hasPolestarCommandAuthorization))
        try keychain.saveCommandSessionToken("cmd-refresh-token")
        #expect(store.hasPolestarCommandAuthorization)
        try keychain.deleteCommandSessionToken()
        #expect(!(store.hasPolestarCommandAuthorization))
    }

    @Test
    func testScheduleKindAndWeekdays() {
        let climateSchedule = VehicleSchedule(
            backendID: "timer-123",
            index: 0,
            kind: .climate,
            startHour: 8,
            startMinute: 15,
            endHour: nil,
            endMinute: nil,
            weekdays: [.monday, .wednesday, .friday],
            isActive: true
        )
        #expect(climateSchedule.kind == .climate)
        #expect(climateSchedule.startHour == 8)
        #expect(climateSchedule.startMinute == 15)
        #expect(climateSchedule.weekdays.count == 3)
        #expect(climateSchedule.isActive)
        #expect(climateSchedule.backendID == "timer-123")

        let chargeSchedule = VehicleSchedule(
            backendID: nil,
            index: 1,
            kind: .globalCharging,
            startHour: 23,
            startMinute: 0,
            endHour: 6,
            endMinute: 30,
            weekdays: [.saturday, .sunday],
            isActive: true
        )
        #expect(chargeSchedule.kind == .globalCharging)
        #expect(chargeSchedule.startHour == 23)
        #expect(chargeSchedule.endHour == 6)
        #expect(chargeSchedule.endMinute == 30)
    }

    @Test
    func testRemoteEngineStartCommandAttributesAndBrandImplementation() {
        let start = RemoteCommand.startEngine(runtimeMinutes: 15)
        let stop = RemoteCommand.stopEngine

        #expect(start.isImplemented(by: .volvo))
        #expect(!(start.isImplemented(by: .polestar)))
        #expect(stop.isImplemented(by: .volvo))
        #expect(!(stop.isImplemented(by: .polestar)))

        #expect(start.feature == .remoteClimate)
        #expect(stop.feature == .remoteClimate)
        #expect(start.requiredCapability == .engineStart)
        #expect(stop.requiredCapability == .engineStart)
        #expect(start.risk == .securitySensitive)
        #expect(stop.risk == .routine)
        #expect(start.identifier == "start-engine")
        #expect(stop.identifier == "stop-engine")
    }

    @Test
    func testVolvoReducedGuardCommandAttributes() {
        let command = RemoteCommand.lockReducedGuard
        #expect(command.isImplemented(by: .volvo))
        #expect(!(command.isImplemented(by: .polestar)))
        #expect(command.feature == .remoteLocks)
        #expect(command.requiredCapability == .reducedGuardLock)
        #expect(command.identifier == "lock-reduced-guard")
        #expect(command.risk == .routine)
    }

    @Test
    func testWarrantyDatesAreNeverDerivedFromBuildMetadata() {
        let state = VehicleState(
            batteryPercentage: 80.0,
            rangeKm: 50,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 100,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .unknown,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Volvo XC60 T8 Recharge",
            modelYear: "2024",
            registrationNo: "HYB123",
            vin: "YV1XZEHR2R2371256",
            ownerFirstName: "Nico",
            odometerKm: 12000,
            daysToService: 240,
            distanceToServiceKm: 18000,
            serviceWarning: false,
            fluidWarnings: [],
            powertrain: .phev,
            fuelLevelPercent: 75.0,
            fuelRangeKm: 550,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )

        #expect(state.maintenance.warranty == nil)

        var polestarState = VehicleState(
            batteryPercentage: 75.0,
            rangeKm: 270,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 90,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .unknown,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2 Long Range Dual Motor",
            modelYear: "2023",
            registrationNo: "PLS789",
            vin: "YSMVSEDE6PL147228",
            ownerFirstName: "Nico",
            odometerKm: 42000,
            daysToService: 340,
            distanceToServiceKm: 12000,
            serviceWarning: false,
            fluidWarnings: [],
            powertrain: .bev,
            fuelLevelPercent: nil,
            fuelRangeKm: nil,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
        polestarState.identity.structureWeek = "202245"

        #expect(polestarState.maintenance.warranty == nil)
    }

    @Test
    func testLockAndUnlockWireRequests() throws {
        let lockData = PolestarGRPC.lockRequest("VIN123")
        let lockFields = Protobuf.fields(lockData)
        let lockEnvelope = try #require(lockFields.first { $0.number == 1 && $0.wire == 2 }?.data)
        #expect(string(lockEnvelope, field: 1) == "VIN123")
        #expect(lockFields.first { $0.number == 2 }?.varint == 0)

        let unlockAllData = PolestarGRPC.unlockRequest("VIN123", trunkOnly: false)
        let unlockAllFields = Protobuf.fields(unlockAllData)
        let unlockAllEnvelope = try #require(unlockAllFields.first { $0.number == 1 && $0.wire == 2 }?.data)
        #expect(string(unlockAllEnvelope, field: 1) == "VIN123")
        #expect(unlockAllFields.first { $0.number == 2 }?.varint == 0)

        let unlockTrunkData = PolestarGRPC.unlockRequest("VIN123", trunkOnly: true)
        let unlockTrunkFields = Protobuf.fields(unlockTrunkData)
        let unlockTrunkEnvelope = try #require(unlockTrunkFields.first { $0.number == 1 && $0.wire == 2 }?.data)
        #expect(string(unlockTrunkEnvelope, field: 1) == "VIN123")
        #expect(unlockTrunkFields.first { $0.number == 2 }?.varint == 1)
    }

    @Test
    func testWindowControlAndPreCleaningWireRequests() throws {
        let openData = PolestarGRPC.windowRequest("VIN123", action: 1)
        let openFields = Protobuf.fields(openData)
        #expect(openFields.first { $0.number == 2 }?.varint == 1)

        let closeData = PolestarGRPC.windowRequest("VIN123", action: 2)
        let closeFields = Protobuf.fields(closeData)
        #expect(closeFields.first { $0.number == 2 }?.varint == 2)

        let startPreclean = PolestarGRPC.preCleaningRequest(vin: "VIN123", start: true)
        let startFields = Protobuf.fields(startPreclean)
        #expect(startFields.first { $0.number == 2 }?.varint == 1)

        let stopPreclean = PolestarGRPC.preCleaningRequest(vin: "VIN123", start: false)
        let stopFields = Protobuf.fields(stopPreclean)
        #expect(stopFields.first { $0.number == 2 }?.varint == 0)

        // Folded from RequestConstructionTests (TESTS-13): window and pre-clean envelopes
        // must carry the target VIN in their inner field 1.
        for fields in [openFields, closeFields, startFields, stopFields] {
            let envelope = try #require(fields.first { $0.number == 1 && $0.wire == 2 }?.data)
            #expect(string(envelope, field: 1) == "VIN123")
        }
    }

    @Test
    func testChronosEnvelopeConstruction() throws {
        var payload = Data()
        payload.append(Protobuf.intField(2, 90))
        let chronosData = PolestarGRPC.chronosRequest("VIN123", payload: payload)
        let fields = Protobuf.fields(chronosData)
        let envelope = try #require(fields.first { $0.number == 1 && $0.wire == 2 }?.data)
        let envFields = Protobuf.fields(envelope)
        #expect(!(string(envelope, field: 1)?.isEmpty ?? true))
        #expect(string(envelope, field: 2) == "VIN123")
        #expect(string(envelope, field: 3) == "RCS")
        #expect(envFields.first { $0.number == 4 && $0.wire == 2 } != nil)
        #expect(fields.first { $0.number == 2 }?.varint == 90)
    }

    @Test
    func testFetchAmpLimitResponseParsing() {
        var validInner = Data()
        validInner.append(Protobuf.intField(1, 32))
        var validBody = Data()
        validBody.append(Protobuf.messageField(3, validInner))
        #expect(PolestarGRPC.fetchAmpLimitResponse(validBody) == 32)

        var invalidInner = Data()
        invalidInner.append(Protobuf.intField(1, 100))
        var invalidBody = Data()
        invalidBody.append(Protobuf.messageField(3, invalidInner))
        #expect(PolestarGRPC.fetchAmpLimitResponse(invalidBody) == nil)

        #expect(PolestarGRPC.fetchAmpLimitResponse(Data()) == nil)
    }

    @Test
    func testChronosSetAmpLimitAndChargeNowResponseParsing() throws {
        // SetAmpLimit returns status = 1 at field 3 (varint)
        var setAmpBody = Data()
        setAmpBody.append(Protobuf.stringField(1, "56e88e65-e8ab-469d-aa34-5881caac61a5"))
        setAmpBody.append(Protobuf.stringField(2, "YSMVSEDE6PL147228"))
        setAmpBody.append(Protobuf.intField(3, 1))
        let setAmpResult = try PolestarGRPC.chronosResult(setAmpBody, statusField: 3)
        #expect(setAmpResult.outcome == .accepted)

        // StartOverrideChargeTimer returns status = 2 at top-level field 1 (varint)
        let chargeNowBody = Data([0x08, 0x02])
        let fields = Protobuf.fields(chargeNowBody)
        let status = fields.first(where: { $0.number == 1 && $0.wire == 0 })?.varint
        #expect(status == 2)
    }

    @Test
    func testCommandErrorStatusMapping() {
        let err3 = PolestarGRPC.commandError(status: "3", message: "relativeTime%20out%20of%20bounds", path: "SchedulerService/Schedule")
        guard case RemoteCommandError.rejected(let msg3) = err3 else {
            Issue.record("Expected rejected error for status 3")
            return
        }
        #expect(msg3 == "relativeTime out of bounds")

        let err12 = PolestarGRPC.commandError(status: "12", message: nil, path: "ota_mobcache.SchedulerService/Download")
        #expect(err12 is PolestarError)

        let err14 = PolestarGRPC.commandError(status: "14", message: nil, path: "services.vehiclestates.battery.BatteryService")
        #expect(err14 is PolestarError)

        let err16 = PolestarGRPC.commandError(status: "16", message: nil, path: "invocation.InvocationService/Lock")
        guard case RemoteCommandError.rejected(let msg16) = err16 else {
            Issue.record("Expected rejected error for status 16")
            return
        }
        #expect(msg16?.contains("mobile app") == true)
    }

    @Test
    func testOptimisticStateLockDuringCommandGracePeriod() {
        var previous = VehicleState(
            batteryPercentage: 80.0,
            rangeKm: 350,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 70,
            chargingPowerWatts: nil,
            chargingCurrentAmps: 16,
            chargingVoltageVolts: nil,
            chargingType: .unknown,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2023",
            registrationNo: "ZCJ06G",
            vin: "YSMVSEDE6PL147228",
            ownerFirstName: "Nico",
            odometerKm: 30000,
            daysToService: 100,
            distanceToServiceKm: 15000,
            serviceWarning: false,
            fluidWarnings: [],
            climateStatus: VehicleClimateStatus(
                activity: .heating,
                timeRemainingMinutes: 30,
                timerTriggered: false,
                interiorTemperatureCelsius: 18.0,
                requestedTemperatureCelsius: 22.0
            ),
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
        previous.commandState.optimisticLockUntil = Date().addingTimeInterval(90)

        // Incoming fresh state from stale cloud cache reporting idle climate and old 90% target
        let staleIncoming = VehicleState(
            batteryPercentage: 80.0,
            rangeKm: 350,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 90,
            chargingPowerWatts: nil,
            chargingCurrentAmps: 32,
            chargingVoltageVolts: nil,
            chargingType: .unknown,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2023",
            registrationNo: "ZCJ06G",
            vin: "YSMVSEDE6PL147228",
            ownerFirstName: "Nico",
            odometerKm: 30000,
            daysToService: 100,
            distanceToServiceKm: 15000,
            serviceWarning: false,
            fluidWarnings: [],
            climateStatus: VehicleClimateStatus(
                activity: .idle,
                timeRemainingMinutes: nil,
                timerTriggered: false,
                interiorTemperatureCelsius: 18.0,
                requestedTemperatureCelsius: nil
            ),
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )

        var features = FeatureSelection.default
        features.set(.climateStatus, enabled: true)
        features.set(.remoteClimate, enabled: true)
        features.set(.remoteCharging, enabled: true)

        let merged = staleIncoming.mergingLastKnown(from: previous, features: features)

        // Should preserve optimistic active climate and charge target during the 90s grace window
        #expect(merged.climateStatus?.activity == .heating)
        #expect(merged.energy.targetPercentage == 70)
        #expect(merged.energy.currentAmps == 16)
    }

    @Test
    func testStartingTelemetryReplacesOptimisticClimateDuringGracePeriod() {
        // Regression: the car sits in the backend's STARTING state after a start command,
        // and that reading must count as a live session – replacing the synthesized
        // optimistic heating instead of being discarded as a non-running state, while a
        // stale idle frame still cannot revert the lock.
        var previous = VehicleState(
            batteryPercentage: 80.0,
            rangeKm: 350,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 70,
            chargingPowerWatts: nil,
            chargingCurrentAmps: 16,
            chargingVoltageVolts: nil,
            chargingType: .unknown,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2023",
            registrationNo: "ZCJ06G",
            vin: "YSMVSEDE6PL147228",
            ownerFirstName: "Nico",
            odometerKm: 30000,
            daysToService: nil,
            distanceToServiceKm: nil,
            serviceWarning: false,
            fluidWarnings: [],
            climateStatus: VehicleClimateStatus(
                activity: .heating,
                timeRemainingMinutes: 30,
                timerTriggered: false,
                interiorTemperatureCelsius: 18.0,
                requestedTemperatureCelsius: 22.0
            ),
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
        previous.commandState.optimisticLockUntil = Date().addingTimeInterval(90)

        func incoming(activity: ClimateActivity) -> VehicleState {
            VehicleState(
                batteryPercentage: 80.0,
                rangeKm: 350,
                chargingState: .idle,
                estimatedChargingTimeToFullMinutes: nil,
                chargeTargetPercentage: 70,
                chargingPowerWatts: nil,
                chargingCurrentAmps: 16,
                chargingVoltageVolts: nil,
                chargingType: .unknown,
                chargerConnection: .disconnected,
                availability: .available,
                modelName: "Polestar 2",
                modelYear: "2023",
                registrationNo: "ZCJ06G",
                vin: "YSMVSEDE6PL147228",
                ownerFirstName: "Nico",
                odometerKm: 30000,
                daysToService: nil,
                distanceToServiceKm: nil,
                serviceWarning: false,
                fluidWarnings: [],
                climateStatus: VehicleClimateStatus(
                    activity: activity,
                    timeRemainingMinutes: activity == .starting ? 30 : nil,
                    timerTriggered: false,
                    interiorTemperatureCelsius: 18.0,
                    requestedTemperatureCelsius: 22.0
                ),
                imageData: nil,
                fetchedAt: Date(),
                vehicleReportedAt: Date(),
                dataWarnings: []
            )
        }

        var features = FeatureSelection.default
        features.set(.climateStatus, enabled: true)

        let started = incoming(activity: .starting).mergingLastKnown(from: previous, features: features)
        #expect(started.climateStatus?.activity == .starting)
        #expect(started.isClimateActive)

        let staleIdle = incoming(activity: .idle).mergingLastKnown(from: started, features: features)
        #expect(staleIdle.climateStatus?.activity == .starting)
    }

    @Test
    func testClimateActivitySessionClassification() {
        for active: ClimateActivity in [.active, .starting, .heating, .cooling, .ventilating] {
            #expect(active.isActiveSession, "\(active) must count as a running session")
        }
        for inactive: ClimateActivity in [.unknown, .idle] {
            #expect(!inactive.isActiveSession, "\(inactive) must not count as a running session")
        }
    }

    private func invocation(status: Int) -> Data {
        var response = Data()
        response.append(Protobuf.intField(3, status))
        return Protobuf.messageField(1, response)
    }

    private func string(_ data: Data, field: Int) -> String? {
        guard let bytes = Protobuf.fields(data).first(where: { $0.number == field })?.data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private func float(_ data: Data?) -> Float? {
        guard let data, data.count == 4 else { return nil }
        let bits = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        return Float(bitPattern: bits)
    }
}

@MainActor
private final class DeferredCommandAuthorizer: RemoteActionAuthorizing {
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var authorizationRequested = false

    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool {
        authorizationRequested = true
        requestContinuation?.resume()
        requestContinuation = nil
        return await withCheckedContinuation { authorizationContinuation = $0 }
    }

    func waitForAuthorizationRequest() async {
        guard !authorizationRequested else { return }
        await withCheckedContinuation { requestContinuation = $0 }
    }

    func allow() {
        authorizationContinuation?.resume(returning: true)
        authorizationContinuation = nil
    }
}

@MainActor
private final class CommandContextMock: CommandExecutionContext {
    var vehicleState: VehicleState?
    var sessionIsValid = true
    private let provider: CommandContextProvider

    init(provider: CommandContextProvider, vehicleState: VehicleState) {
        self.provider = provider
        self.vehicleState = vehicleState
    }

    func currentCommandExecutor() -> any RemoteCommandExecuting { provider }
    func commandInProgressDidChange() {}
    func presentResult(
        title: String, message: String, success: Bool, target: RemoteCommandTarget?
    ) {}
    func beginCommandConfirmation(
        _ receipt: CommandReceipt,
        optimisticState: VehicleState?
    ) {
        if let optimisticState { vehicleState = optimisticState }
        vehicleState?.commandState.receipt = receipt
    }
}

private actor CommandContextProvider: RemoteCommandExecuting {
    nonisolated let brand: VehicleBrand = .polestar
    private var executedVINs: [String] = []
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        executedVINs.append(vin)
        return RemoteCommandResult(outcome: .completed, message: nil)
    }

    func executedCount() -> Int { executedVINs.count }
}
