import Foundation
import Testing
@testable import Hisingen

struct PolestarC3RemainingFieldsTests {
    // MARK: Energy use per period (battery 20–25)

    @Test func periodBreakdownJoinsWattHoursAndPercentageByCategory() throws {
        let payload = Protobuf.messageField(20, Protobuf.intField(1, 5) + Protobuf.intField(2, 1_200)
                + Protobuf.intField(3, 300) + Protobuf.intField(4, 900))
            + Protobuf.messageField(23, Protobuf.intField(1, 3) + Protobuf.intField(2, 70)
                + Protobuf.intField(3, 15) + Protobuf.intField(4, 12))
            + Protobuf.messageField(21, Protobuf.intField(2, 40))
        let battery = try PolestarGRPC.parseBattery(payload)
        let periods = try #require(battery.diagnostics.energyBreakdownByPeriod)

        let manual = try #require(periods.manualTrip)
        #expect(manual.driving == EnergyBreakdownItem(wattHours: 1_200, percentage: 70))
        #expect(manual.climate == EnergyBreakdownItem(wattHours: 300, percentage: 15))
        #expect(manual.battery == EnergyBreakdownItem(wattHours: 900, percentage: 12))
        #expect(manual.other == EnergyBreakdownItem(wattHours: 5, percentage: 3))

        let automatic = try #require(periods.automaticTrip)
        #expect(automatic.driving == EnergyBreakdownItem(wattHours: 40, percentage: nil))
        #expect(automatic.climate == nil)
        #expect(periods.sinceCharge == nil)
        #expect(battery.unknownFields.isEmpty)
    }

    @Test func absentPeriodsStayNil() throws {
        let battery = try PolestarGRPC.parseBattery(Protobuf.intField(7, 2))
        #expect(battery.diagnostics.energyBreakdownByPeriod == nil)
        #expect(battery.unknownFields.isEmpty)
    }

    @Test(arguments: zip([20, 20, 21, 22, 23, 25], [
        Protobuf.messageField(20, Data()),
        Protobuf.intField(20, 5),
        Protobuf.messageField(21, Protobuf.intField(5, 1)),
        Protobuf.messageField(22, Protobuf.doubleField(2, 1)),
        Protobuf.messageField(23, Protobuf.intField(2, -1)),
        Protobuf.messageField(25, Protobuf.intField(2, 1) + Protobuf.doubleField(2, 1))
    ]).map { ($0, $1) })
    func malformedPeriodFieldsStayRaw(number: Int, payload: Data) throws {
        let battery = try PolestarGRPC.parseBattery(payload)
        #expect(battery.diagnostics.energyBreakdownByPeriod == nil)
        #expect(battery.unknownFields.map(\.field) == [number])
    }

    @Test func unknownCategoryTagInsidePeriodStaysRaw() throws {
        let battery = try PolestarGRPC.parseBattery(
            Protobuf.messageField(22, Protobuf.intField(2, 10) + Protobuf.intField(5, 1))
        )
        #expect(battery.diagnostics.energyBreakdownByPeriod == nil)
        #expect(battery.unknownFields.map(\.field) == [22])
    }

    // MARK: Discharge information (battery 27)

    @Test func dischargeInfoDecodesFloatValues() throws {
        let payload = Protobuf.messageField(27, Protobuf.floatField(1, 62.4) + Protobuf.floatField(2, 5.2)
            + Protobuf.floatField(3, 240))
        let battery = try PolestarGRPC.parseBattery(payload)
        let available = try #require(battery.diagnostics.energyAvailableKwh)
        let increase = try #require(battery.diagnostics.energyAvailableIncreaseKwh)
        #expect(abs(available - 62.4) < 0.001)
        #expect(abs(increase - 5.2) < 0.001)
        #expect(battery.diagnostics.powerLimitKw == 240)
        #expect(battery.unknownFields.isEmpty)
    }

    @Test func absentDischargeInfoLeavesPowerLimitNil() throws {
        let battery = try PolestarGRPC.parseBattery(Protobuf.intField(7, 2))
        #expect(battery.diagnostics.powerLimitKw == nil)
        #expect(battery.diagnostics.energyAvailableKwh == nil)
    }

    @Test(arguments: [
        Protobuf.messageField(27, Protobuf.doubleField(3, 240)),
        Protobuf.messageField(27, Protobuf.floatField(3, .nan)),
        Protobuf.messageField(27, Protobuf.floatField(3, -1)),
        Protobuf.messageField(27, Protobuf.floatField(4, 1)),
        Protobuf.messageField(27, Data()),
        Protobuf.intField(27, 240)
    ])
    func malformedDischargeInfoStaysRaw(payload: Data) throws {
        let battery = try PolestarGRPC.parseBattery(payload)
        #expect(battery.diagnostics.powerLimitKw == nil)
        #expect(battery.diagnostics.energyAvailableKwh == nil)
        #expect(battery.unknownFields.map(\.field) == [27])
    }

    // MARK: Manual preconditioning (battery 29)

    @Test func manualPreconditioningDecodesStatusAndEnd() throws {
        let payload = Protobuf.messageField(29, Protobuf.intField(1, 3)
            + Protobuf.messageField(3, Protobuf.intField(1, 1_800_000_000)))
        let battery = try PolestarGRPC.parseBattery(payload)
        #expect(battery.diagnostics.batteryPreconditioningStatus == "MANUAL_PRECONDITIONING_STATUS_ON")
        #expect(battery.diagnostics.batteryPreconditioningEndsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(battery.unknownFields.isEmpty)
    }

    @Test func unspecifiedPreconditioningStatusIsNilButStillDecoded() throws {
        let payload = Protobuf.messageField(29, Protobuf.intField(1, 0)
            + Protobuf.messageField(3, Protobuf.intField(1, 5)))
        let battery = try PolestarGRPC.parseBattery(payload)
        #expect(battery.diagnostics.batteryPreconditioningStatus == nil)
        #expect(battery.diagnostics.batteryPreconditioningEndsAt == Date(timeIntervalSince1970: 5))
        #expect(battery.unknownFields.isEmpty)
    }

    @Test(arguments: [
        Protobuf.messageField(29, Protobuf.intField(1, 9)),
        Protobuf.messageField(29, Protobuf.stringField(1, "x")),
        Protobuf.messageField(29, Protobuf.intField(1, 3) + Protobuf.intField(2, 1)),
        Protobuf.messageField(29, Protobuf.intField(1, 3) + Protobuf.messageField(3, Protobuf.stringField(1, "x"))),
        Protobuf.messageField(29, Protobuf.intField(1, 3) + Protobuf.intField(3, 1_800_000_000)),
        Protobuf.messageField(29, Data()),
        Protobuf.intField(29, 3)
    ])
    func malformedPreconditioningStaysRaw(payload: Data) throws {
        let battery = try PolestarGRPC.parseBattery(payload)
        #expect(battery.diagnostics.batteryPreconditioningStatus == nil)
        #expect(battery.diagnostics.batteryPreconditioningEndsAt == nil)
        #expect(battery.unknownFields.map(\.field) == [29])
    }

    // MARK: Cold battery status (battery 30)

    @Test(arguments: zip(1...5, [ColdBatteryStatus.normal, .coldPredicted, .coldAndLowSOCPredicted, .cold, .coldAndLowSOC]).map { ($0, $1) })
    func coldBatteryStatusMapsEnumNumbers(raw: Int, expected: ColdBatteryStatus) throws {
        let battery = try PolestarGRPC.parseBattery(Protobuf.intField(30, raw))
        #expect(battery.diagnostics.coldBatteryStatus == expected)
        #expect(battery.unknownFields.isEmpty)
    }

    @Test func unspecifiedColdBatteryStatusIsNilAndDecoded() throws {
        let battery = try PolestarGRPC.parseBattery(Protobuf.intField(30, 0))
        #expect(battery.diagnostics.coldBatteryStatus == nil)
        #expect(battery.unknownFields.isEmpty)
    }

    @Test(arguments: [Protobuf.intField(30, 6), Protobuf.intField(30, 99), Protobuf.stringField(30, "COLD")])
    func unknownOrWrongColdBatteryValuesStayRaw(payload: Data) throws {
        let battery = try PolestarGRPC.parseBattery(payload)
        #expect(battery.diagnostics.coldBatteryStatus == nil)
        #expect(battery.unknownFields.map(\.field) == [30])
    }

    @Test func coldStatesThatLimitChargingAreOnlyTheCurrentOnes() {
        #expect(ColdBatteryStatus.cold.limitsCharging)
        #expect(ColdBatteryStatus.coldAndLowSOC.limitsCharging)
        #expect(!ColdBatteryStatus.coldPredicted.limitsCharging)
        #expect(!ColdBatteryStatus.normal.limitsCharging)
    }

    // MARK: Persistence

    @Test func snapshotsWithoutNewKeysStillDecode() throws {
        let old = try JSONDecoder().decode(BatteryDiagnostics.self, from: Data(#"{"chargerPowerState":"unknown"}"#.utf8))
        #expect(old.energyBreakdownByPeriod == nil)
        #expect(old.coldBatteryStatus == nil)
        #expect(old.powerLimitKw == nil)
    }

    @Test func newBatteryFieldsRoundTripThroughState() throws {
        let payload = Protobuf.messageField(22, Protobuf.intField(2, 10))
            + Protobuf.messageField(27, Protobuf.floatField(3, 180))
            + Protobuf.intField(30, 4)
        var state = vehicle(vin: "TEST-VIN")
        state.applyLiveUpdate(.battery(try PolestarGRPC.parseBattery(payload)))
        let restored = try JSONDecoder().decode(VehicleState.self, from: JSONEncoder().encode(state))
        #expect(restored.energy.diagnostics?.energyBreakdownByPeriod?.sinceCharge?.driving?.wattHours == 10)
        #expect(restored.energy.diagnostics?.powerLimitKw == 180)
        #expect(restored.energy.diagnostics?.coldBatteryStatus == .cold)
    }

    // MARK: Climate warnings (climate 5)

    private func twin(_ fields: Data) -> VehicleClimateStatus {
        PolestarGRPC.parseClimate(Protobuf.messageField(1, Protobuf.intField(1, 1)) + fields)
    }

    @Test func climateWarningsDecodeSingleAndPacked() {
        let single = twin(Protobuf.intField(5, 2))
        #expect(single.climateWarnings == ["RUN_TIME_NEARING_LIMIT"])
        #expect(single.unknownWireFields == nil)

        let packed = twin(Protobuf.packedIntField(5, [1, 2]))
        #expect(packed.climateWarnings == ["BATTERY_LOW", "RUN_TIME_NEARING_LIMIT"])
        #expect(packed.unknownWireFields == nil)
    }

    @Test func absentClimateWarningsStayNil() {
        let result = twin(Protobuf.intField(2, 1))
        #expect(result.climateWarnings == nil)
        #expect(result.unknownWireFields == nil)
    }

    @Test(arguments: [
        Protobuf.intField(5, 3),
        Protobuf.intField(5, 0),
        Protobuf.packedIntField(5, [1, 9]),
        Protobuf.stringField(5, "x")
    ])
    func unknownOrWrongClimateWarningsStayRaw(payload: Data) {
        let result = twin(payload)
        #expect(result.unknownWireFields?.map(\.field) == [5])
    }

    @Test func legacyClimateFrameDoesNotReadWarnings() {
        let result = PolestarGRPC.parseClimate(Protobuf.intField(1, 5) + Protobuf.intField(5, 1))
        #expect(result.climateWarnings == nil)
        #expect(result.unknownWireFields?.first?.field == 5)
    }

    @Test func climateWarningNamesCoverOnlyDecodedTokens() {
        #expect(VehicleClimateStatus.climateWarningName("BATTERY_LOW") != nil)
        #expect(VehicleClimateStatus.climateWarningName("RUN_TIME_NEARING_LIMIT") != nil)
        #expect(VehicleClimateStatus.climateWarningName("SOMETHING_ELSE") == nil)
    }

    // MARK: Reader surfaces

    @Test @MainActor func batteryDiagnosticsShowEnergyUseOnlyWhenReported() throws {
        var energy = EnergyAndChargingSnapshot()
        energy.diagnostics = BatteryDiagnostics(
            timeToTargetMinutes: nil, timeToMinimumSOCMinutes: nil,
            chargerPowerState: .unknown, averageConsumption: nil,
            averageConsumptionSinceCharge: nil, energyUsedSinceChargeWh: nil
        )
        let empty = InfoTabView.batteryDiagnosticRows(energy: energy, energyUnit: .kwhPer100Km)
        #expect(!empty.contains { $0.key.contains(L10n.text("Energy Use")) })
        #expect(!empty.contains { $0.key == L10n.text("Cold Battery") })
        #expect(!empty.contains { $0.key == L10n.text("Power Limit") })

        energy.diagnostics?.energyBreakdownByPeriod = EnergyBreakdownByPeriod(
            manualTrip: EnergyBreakdownSnapshot(driving: EnergyBreakdownItem(wattHours: 12_500, percentage: 70))
        )
        energy.diagnostics?.powerLimitKw = 240
        energy.diagnostics?.coldBatteryStatus = .coldAndLowSOC
        let rows = InfoTabView.batteryDiagnosticRows(energy: energy, energyUnit: .kwhPer100Km)
        let usage = try #require(rows.first { $0.key.contains(L10n.text("Energy Use")) })
        #expect(usage.key.contains(L10n.text("Trip Meter (TM)")))
        #expect(!rows.contains { $0.key.contains(L10n.text("Automatic Trip (AT)")) && $0.key.contains(L10n.text("Energy Use")) })
        #expect(rows.contains { $0.key == L10n.text("Power Limit") })
        let cold = try #require(rows.first { $0.key == L10n.text("Cold Battery") })
        #expect(cold.info == L10n.text("Charging power may be limited while the battery is cold."))
    }

    @Test @MainActor func energyUseSummaryNamesOnlyReportedCategories() {
        let breakdown = EnergyBreakdownSnapshot(
            driving: EnergyBreakdownItem(wattHours: 12_500, percentage: 70),
            climate: EnergyBreakdownItem(wattHours: nil, percentage: 15)
        )
        let summary = InfoTabView.energyUseSummary(breakdown)
        #expect(summary == "\(L10n.text("Driving")) 12.5 kWh (70%) · \(L10n.text("Climate")) (15%)")
        #expect(InfoTabView.energyUseSummary(EnergyBreakdownSnapshot()) == nil)
    }

    @Test @MainActor func climateWarningsAppearInAttentionRowsWhenReported() {
        var state = vehicle(vin: "TEST-VIN")
        state.climateStatus = VehicleClimateStatus(activity: .idle, timeRemainingMinutes: nil, timerTriggered: false,
                                                   climateWarnings: ["RUN_TIME_NEARING_LIMIT"])
        let rows = ExceptionsCard.attentionRows(state: state, features: FeatureSelection(enabled: [.climateStatus]),
                                                dismissedSoftwareEventIdentifier: nil)
        #expect(rows.contains { $0.key == L10n.text("Climate Warning") })

        state.climateStatus?.climateWarnings = nil
        let quiet = ExceptionsCard.attentionRows(state: state, features: FeatureSelection(enabled: [.climateStatus]),
                                                 dismissedSoftwareEventIdentifier: nil)
        #expect(!quiet.contains { $0.key == L10n.text("Climate Warning") })
    }
}

@MainActor
@Suite("Climate warning notices")
struct ClimateWarningNoticeTests {
    private func climateState(_ harness: NotificationTestHarness, warnings: [String]?,
                              session: Date?, reportedAt: Date = Date()) -> VehicleState {
        var state = harness.makeState(reportedAt: reportedAt)
        state.climateStatus = VehicleClimateStatus(
            activity: .heating, timeRemainingMinutes: 5, timerTriggered: false,
            sessionStartedAt: session, climateWarnings: warnings
        )
        state.freshness.readingDates[.climateStatus] = reportedAt
        return state
    }

    private func warningPosts(_ harness: NotificationTestHarness) -> Int {
        harness.dispatcher.added.filter { $0.identifier.contains("climate-warning") }.count
    }

    @Test func postsOncePerClimateSession() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyClimateChanges = true
        let notifier = harness.makeNotifier()
        let session = Date(timeIntervalSinceNow: -600)
        let warned = climateState(harness, warnings: ["RUN_TIME_NEARING_LIMIT"], session: session)

        notifier.vehicleStateDidUpdate(warned)
        notifier.vehicleStateDidUpdate(climateState(harness, warnings: ["RUN_TIME_NEARING_LIMIT"], session: session))
        await harness.drainNotificationHops()
        #expect(warningPosts(harness) == 1)

        let nextSession = Date(timeIntervalSinceNow: -60)
        notifier.vehicleStateDidUpdate(climateState(harness, warnings: ["BATTERY_LOW"], session: nextSession))
        await harness.drainNotificationHops()
        #expect(warningPosts(harness) == 2)
    }

    @Test func mutedNotificationPreferenceSuppressesWarning() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyClimateChanges = false
        let notifier = harness.makeNotifier()
        notifier.vehicleStateDidUpdate(climateState(harness, warnings: ["BATTERY_LOW"], session: Date()))
        await harness.drainNotificationHops()
        #expect(warningPosts(harness) == 0)
    }

    @Test func withoutSessionStartOnlyTheFirstReadingNotifies() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyClimateChanges = true
        let notifier = harness.makeNotifier()
        notifier.vehicleStateDidUpdate(climateState(harness, warnings: ["BATTERY_LOW"], session: nil))
        notifier.vehicleStateDidUpdate(climateState(harness, warnings: ["BATTERY_LOW"], session: nil))
        await harness.drainNotificationHops()
        #expect(warningPosts(harness) == 1)
    }

    @Test func unlistedWarningsDoNotNotify() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyClimateChanges = true
        let notifier = harness.makeNotifier()
        notifier.vehicleStateDidUpdate(climateState(harness, warnings: nil, session: Date()))
        await harness.drainNotificationHops()
        #expect(warningPosts(harness) == 0)
    }
}
