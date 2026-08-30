import Foundation
import Testing
@testable import Hisingen

@Suite("Vehicle feature completion")
@MainActor
struct VehicleFeatureCompletionTests {
    @Test
    func bounds() throws {
        #expect(VehicleChargeBounds(capabilities: nil).targetRange == 40...100)
        #expect(VehicleChargeBounds(capabilities: nil).amperageRange == 6...32)

        let advertised = VehicleOTACapabilities(
            chargeAmperageMinLimit: 8,
            chargeAmperageMaxLimit: 24,
            targetChargeLevelPercentageMinLimit: 50
        )
        let advertisedBounds = VehicleChargeBounds(capabilities: advertised)
        #expect(advertisedBounds.targetRange == 50...100)
        #expect(advertisedBounds.amperageRange == 8...24)
        #expect(advertisedBounds.targetPresets() == [50, 60, 70, 80, 90, 100])
        #expect(advertisedBounds.amperagePresets() == [8, 10, 13, 16, 20, 24])

        // GetMyCarsResponse -> MyCar -> Car -> Charging settings messages.
        var ampSettings = Data()
        ampSettings.append(Protobuf.intField(1, 6))
        ampSettings.append(Protobuf.intField(2, 32))
        var targetSettings = Data()
        targetSettings.append(Protobuf.intField(1, 40))
        var charging = Data()
        charging.append(Protobuf.intField(1, 1))
        charging.append(Protobuf.messageField(8, targetSettings))
        charging.append(Protobuf.messageField(9, ampSettings))
        var car = Data()
        car.append(Protobuf.stringField(1, "YSMYTESTVIN123456"))
        car.append(Protobuf.messageField(35, charging))
        var myCar = Data()
        myCar.append(Protobuf.messageField(1, car))
        let response = Protobuf.messageField(1, myCar)
        let decoded = try #require(PolestarGRPC.parseMyCars(response, vin: "ysmytestvin123456"))
        #expect(decoded.supportsGlobalChargeAmperageLimit)
        #expect(decoded.supportsTargetChargeLevel)
        #expect(decoded.chargeAmperageMinLimit == 6)
        #expect(decoded.chargeAmperageMaxLimit == 32)
        #expect(decoded.targetChargeLevelPercentageMinLimit == 40)
    }

    @Test
    func diagnosticInspector() {
        let now = Date()
        let entries = [
            APILogEntry(timestamp: now, provider: .volvo, method: "GET",
                        endpoint: "https://api.test/energy", operation: "energy status",
                        statusCode: 200, responseBytes: 10, responsePayloadJSON: "{\"soc\":80}",
                        durationMilliseconds: 20, errorType: nil),
            APILogEntry(timestamp: now, provider: .polestar, method: "POST",
                        endpoint: "https://api.test/command", operation: "climate command",
                        statusCode: 503, responseBytes: 0, responsePayloadJSON: nil,
                        durationMilliseconds: 200, errorType: nil),
            APILogEntry(timestamp: now, provider: .polestar, method: "GET",
                        endpoint: "https://api.test/state", operation: "poll",
                        statusCode: nil, responseBytes: nil, responsePayloadJSON: nil,
                        durationMilliseconds: 3, errorType: "URLError: timedOut")
        ]
        #expect(APIDiagnosticInspectorFilter(provider: .polestar).apply(to: entries).count == 2)
        #expect(APIDiagnosticInspectorFilter(outcome: .serverError).apply(to: entries).map(\.operation) == ["climate command"])
        #expect(APIDiagnosticInspectorFilter(outcome: .transportError).apply(to: entries).map(\.operation) == ["poll"])
        #expect(APIDiagnosticInspectorFilter(query: "SOC").apply(to: entries).map(\.operation) == ["energy status"])
    }

    @Test
    func otaNotifications() throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifySoftwareUpdates = true
        let notifier = harness.makeNotifier()
        var state = harness.makeState()
        state.softwareInfo = VehicleSoftwareInfo(version: "4.2", state: .available)
        notifier.vehicleStateDidUpdate(state)

        let transitions: [(SoftwareUpdateState, String)] = [
            (.scheduled, L10n.text("Vehicle software update scheduled")),
            (.downloading, L10n.text("Vehicle software downloading")),
            (.installing, L10n.text("Vehicle software installing"))
        ]
        for (softwareState, expectedTitle) in transitions {
            state.softwareInfo = VehicleSoftwareInfo(version: "4.2", state: softwareState,
                                                     scheduledAt: softwareState == .scheduled ? Date() : nil)
            notifier.vehicleStateDidUpdate(state)
            #expect(harness.dispatcher.added.last?.content.title == expectedTitle)
            let count = harness.dispatcher.added.count
            notifier.vehicleStateDidUpdate(state)
            #expect(harness.dispatcher.added.count == count)
        }
    }

    @Test
    func airQualityHistory() throws {
        let database = VehicleDatabase.inMemory()
        let suite = "HisingenTests.AQI.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VehicleStateStore(defaults: defaults, database: database)
        var polestar = try NotificationTestHarness().makeState()
        polestar.airQuality = VehicleAirQuality(
            cleaningState: .off, airQualityIndex: 18, particulateMatter25: 4
        )
        store.save(polestar)
        #expect(database.recentAirQuality(for: polestar.vin).count == 1)

        let volvo = VehicleState(
            batteryPercentage: 60, rangeKm: 300, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .none, chargerConnection: .disconnected,
            availability: .available, modelName: "Volvo EX30", modelYear: "2026",
            registrationNo: nil, vin: "YV1TESTVOLVO12345", ownerFirstName: nil,
            odometerKm: nil,
            airQuality: VehicleAirQuality(
                cleaningState: .off, airQualityIndex: 70, particulateMatter25: 20
            ),
            powertrain: .bev, imageData: nil, fetchedAt: Date(),
            vehicleReportedAt: Date(), dataWarnings: []
        )
        store.save(volvo)
        #expect(database.recentAirQuality(for: volvo.vin).isEmpty)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let trend = HistoryInsights.airQualityTrend(from: [
            AirQualityRecord(id: 2, vin: polestar.vin, timestamp: base.addingTimeInterval(60),
                             airQualityIndex: 20, particulateMatter25: 5,
                             particulateMatter10: nil, filterRemainingPercent: nil),
            AirQualityRecord(id: 1, vin: polestar.vin, timestamp: base,
                             airQualityIndex: 10, particulateMatter25: 2,
                             particulateMatter10: nil, filterRemainingPercent: nil)
        ])
        #expect(trend.map(\.index) == [10, 20])
    }

    @Test
    func statusItemMenu() throws {
        #expect(Set(StatusItemController.coreContextActions) == [.lock, .climate, .refresh])
        var state = try NotificationTestHarness().makeState()
        state.exteriorStatus = ExteriorSnapshot(openings: [], isLocked: false, alarmTriggered: false)
        #expect(StatusItemController.lockCommand(for: state) == .lock)
        state.exteriorStatus?.isLocked = true
        #expect(StatusItemController.lockCommand(for: state) == .unlock)

        if case .startClimate(let temperature, _, _, _, _, _) = StatusItemController.climateCommand(
            for: state, temperatureCelsius: 21.5
        ) {
            #expect(temperature == 21.5)
        } else {
            Issue.record("Expected start-climate command")
        }
        state.climateStatus = VehicleClimateStatus(
            activity: .heating, timeRemainingMinutes: 20, timerTriggered: false
        )
        #expect(StatusItemController.climateCommand(for: state, temperatureCelsius: 21.5) == .stopClimate)
    }

    @Test
    func tripMileageReport() throws {
        let base = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01 UTC
        let trips = [
            trip(id: "1-2", date: base, distance: 10),
            trip(id: "2-3", date: base.addingTimeInterval(86_400), distance: 20),
            trip(id: "3-4", date: base.addingTimeInterval(2 * 86_400), distance: 5)
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let report = try #require(MonthlyMileageReport.build(
            from: trips,
            purposes: ["1-2": .business, "2-3": .privateTrip],
            calendar: calendar
        ).first)
        #expect(report.businessKm == 10)
        #expect(report.privateKm == 20)
        #expect(report.unclassifiedKm == 5)
        #expect(report.totalKm == 35)

        let database = VehicleDatabase.inMemory()
        database.setTripPurpose(.business, tripID: "1-2", vin: "VIN")
        #expect(database.tripPurposes(for: "VIN")["1-2"] == .business)
        database.setTripPurpose(nil, tripID: "1-2", vin: "VIN")
        #expect(database.tripPurposes(for: "VIN")["1-2"] == nil)
        #expect(MonthlyMileageReport.csv(reports: [report], vin: "VIN").contains("Business km"))
    }

    @Test
    func smartCharging() throws {
        let json = """
        [
          {"SEK_per_kWh":4,"EUR_per_kWh":0.4,"EXR":10,"time_start":"2026-08-30T00:00:00+02:00","time_end":"2026-08-30T00:15:00+02:00"},
          {"SEK_per_kWh":4,"EUR_per_kWh":0.4,"EXR":10,"time_start":"2026-08-30T00:15:00+02:00","time_end":"2026-08-30T00:30:00+02:00"},
          {"SEK_per_kWh":1,"EUR_per_kWh":0.1,"EXR":10,"time_start":"2026-08-30T00:30:00+02:00","time_end":"2026-08-30T00:45:00+02:00"},
          {"SEK_per_kWh":1,"EUR_per_kWh":0.1,"EXR":10,"time_start":"2026-08-30T00:45:00+02:00","time_end":"2026-08-30T01:00:00+02:00"},
          {"SEK_per_kWh":1,"EUR_per_kWh":0.1,"EXR":10,"time_start":"2026-08-30T01:00:00+02:00","time_end":"2026-08-30T01:15:00+02:00"},
          {"SEK_per_kWh":1,"EUR_per_kWh":0.1,"EXR":10,"time_start":"2026-08-30T01:15:00+02:00","time_end":"2026-08-30T01:30:00+02:00"},
          {"SEK_per_kWh":5,"EUR_per_kWh":0.5,"EXR":10,"time_start":"2026-08-30T01:30:00+02:00","time_end":"2026-08-30T01:45:00+02:00"}
        ]
        """
        let prices = try SpotPriceService.decode(Data(json.utf8))
        #expect(prices.count == 7)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-29T22:00:00Z"))
        let result = try #require(SmartChargingRecommendation.cheapestWindow(
            prices: prices, energyKWh: 2, chargingPowerKW: 2, notBefore: now
        ))
        #expect(result.start == prices[2].start)
        #expect(result.end == prices[5].end)
        #expect(abs(result.estimatedCostSEK - 2) < 0.001)
        #expect(result.intervalCount == 4)
        #expect(SpotPriceService.endpoint(date: now, area: .se4)?.absoluteString.contains("SE4.json") == true)
    }

    @Test
    func calendarPreconditioning() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let due = CalendarPreconditioningEvent(identifier: "meeting", title: "Office",
                                               startDate: now.addingTimeInterval(10 * 60), isAllDay: false)
        let early = CalendarPreconditioningEvent(identifier: "later", title: "Later",
                                                 startDate: now.addingTimeInterval(60 * 60), isAllDay: false)
        let allDay = CalendarPreconditioningEvent(identifier: "holiday", title: "Holiday",
                                                  startDate: now.addingTimeInterval(5 * 60), isAllDay: true)
        let planned = CalendarPreconditioningPlanner.dueEvents(
            from: [early, allDay, due], now: now, leadTimeMinutes: 20,
            firedOccurrenceKeys: []
        )
        #expect(planned == [due])
        #expect(CalendarPreconditioningPlanner.dueEvents(
            from: [due], now: now, leadTimeMinutes: 20,
            firedOccurrenceKeys: [due.occurrenceKey]
        ).isEmpty)
        #expect(CalendarPreconditioningPlanner.dueEvents(
            from: [due], now: due.startDate, leadTimeMinutes: 20,
            firedOccurrenceKeys: []
        ).isEmpty)
    }

    private func trip(id: String, date: Date, distance: Double) -> TripHistoryEntry {
        TripHistoryEntry(
            id: id, vin: "VIN", startedAt: date.addingTimeInterval(-900), endedAt: date,
            distanceKm: distance, averageConsumption: nil, ambientTemperatureCelsius: nil,
            startLatitude: nil, startLongitude: nil, endLatitude: nil, endLongitude: nil
        )
    }
}
