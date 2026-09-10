import Foundation
import Testing
@testable import Hisingen

struct VehicleActivityTests {
    private func state(at date: Date, odometer: Int = 1000) -> VehicleState {
        VehicleState(batteryPercentage: 60, rangeKm: 250, chargingState: .idle,
                     estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
                     chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
                     chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
                     modelName: "Polestar 2", modelYear: "2023", registrationNo: nil, vin: "TEST-VIN",
                     ownerFirstName: nil, odometerKm: odometer, daysToService: nil, distanceToServiceKm: nil,
                     serviceWarning: false, fluidWarnings: [], imageData: nil, fetchedAt: date,
                     vehicleReportedAt: date, dataWarnings: [])
    }

    @Test func readingFreshnessDoesNotBorrowAnotherSensorsTimestamp() throws {
        let now = Date()
        var current = state(at: now)
        current.freshness.readingDates = [.battery: now, .locks: now.addingTimeInterval(-3600)]
        #expect(current.hasFreshReading(.battery, now: now))
        #expect(!current.hasFreshReading(.locks, now: now))
        #expect(!current.hasFreshReading(.health, now: now))
        let decoded = try JSONDecoder().decode(VehicleState.self, from: JSONEncoder().encode(current.cacheableCopy))
        #expect(decoded.freshness.readingDates == current.freshness.readingDates)
        current.freshness.isCached = true
        #expect(!current.hasFreshReading(.battery, now: now))
    }

    @Test func departureAssessmentKeepsTargetAndFullEstimatesDistinct() {
        let now = Date()
        var current = state(at: now)
        current.energy.chargingState = .charging
        current.freshness.readingDates = [.battery: now, .charging: now]
        current.energy.estimatedTimeToTargetMinutes = 20
        current.energy.estimatedTimeToFullMinutes = 90
        #expect(current.remainingChargingMinutes == 20)
        #expect(VehicleReadiness.chargingByDeparture(current, departure: now.addingTimeInterval(1800), now: now)
            == L10n.text("The current vehicle estimate finishes before departure."))
        current.energy.estimatedTimeToTargetMinutes = nil
        #expect(current.remainingChargingMinutes == 90)
        #expect(current.chargingEstimateDestination == L10n.text("Full charge"))
        #expect(VehicleReadiness.chargingByDeparture(current, departure: now.addingTimeInterval(1800), now: now)
            == L10n.text("The current vehicle estimate finishes after departure."))
        current.freshness.readingDates[.charging] = now.addingTimeInterval(-3600)
        #expect(VehicleReadiness.chargingByDeparture(current, departure: now.addingTimeInterval(1800), now: now)
            == L10n.text("No current charging estimate is available for this departure."))
    }

    @Test func creatingLocationValidatesEmbeddedSettings() {
        var settings = VehicleControlSettings()
        let command = RemoteCommand.createChargeLocationAtCar(alias: "Home", ampLimit: 16,
                                                              minimumSoc: 40, optimisedCharging: true)
        #expect(settings.rejection(for: command) == nil)
        settings.locationOptimization = false
        #expect(settings.rejection(for: command) != nil)
        settings.locationOptimization = true
        settings.locationAmperage = false
        #expect(settings.rejection(for: command) != nil)
    }

    @Test func readinessDoesNotTreatEmptyHealthCoverageAsHealthy() {
        let now = Date()
        var current = state(at: now)
        current.freshness.readingDates[.health] = now
        current.maintenance.details = VehicleHealthDetails(tyres: [], warnings: [], reportedWarnings: [])
        #expect(VehicleReadiness.checks(current, lowBatteryThreshold: 20, now: now)
            .first { $0.id == "health" }?.status == .unknown)
        current.maintenance.details = VehicleHealthDetails(tyres: [], warnings: [], reportedWarnings: [.washerFluid])
        #expect(VehicleReadiness.checks(current, lowBatteryThreshold: 20, now: now)
            .first { $0.id == "health" }?.status == .reported)
    }

    @Test func pendingReceiptDoesNotRequireAnOptimisticSensorLock() {
        var current = state(at: Date())
        current.commandState.pending = PendingCommandSummary(commandIdentifier: "lock", issuedAt: Date())
        #expect(current.commandState.optimisticLockUntil == nil)
        #expect(current.isAwaitingVehicleConfirmation)
        current.commandState.pending?.issuedAt = Date().addingTimeInterval(-121)
        #expect(current.isAwaitingVehicleConfirmation)
        current.commandState.pending?.issuedAt = Date().addingTimeInterval(-301)
        #expect(!current.isAwaitingVehicleConfirmation)
    }

    @Test func commandConfirmationRequiresMatchingNewVehicleReading() {
        let now = Date()
        let pending = PendingCommandSummary(commandIdentifier: "lock", issuedAt: now.addingTimeInterval(-10), command: .lock)
        var current = state(at: now)
        current.exteriorStatus = ExteriorSnapshot(openings: [], isLocked: true, alarmTriggered: nil,
                                                  reportedAt: now.addingTimeInterval(-20))
        #expect(pending.updatingConfirmation(from: current).confirmedAt == nil)
        current.exteriorStatus?.reportedAt = now
        #expect(pending.updatingConfirmation(from: current).confirmedAt == now)
        current.exteriorStatus?.isLocked = false
        #expect(pending.updatingConfirmation(from: current).confirmedAt == nil)
        current.exteriorStatus?.isLocked = true
        current.freshness.isCached = true
        #expect(pending.updatingConfirmation(from: current).confirmedAt == nil)
        let unobservable = PendingCommandSummary(commandIdentifier: "honk", issuedAt: now.addingTimeInterval(-10), command: .honkHorn)
        #expect(unobservable.updatingConfirmation(from: current).confirmedAt == nil)
        #expect(!unobservable.supportsTelemetryConfirmation)
    }

    @Test func chargingAndTailgateCommandsRequireFreshMatchingTelemetry() {
        let now = Date()
        var current = state(at: now)
        current.freshness.readingDates[.charging] = now
        current.energy.targetPercentage = 90
        current.energy.currentLimitAmps = 16

        let target = PendingCommandSummary(
            commandIdentifier: "set-charge-target", issuedAt: now.addingTimeInterval(-1),
            command: .setChargeTarget(90)
        )
        let amps = PendingCommandSummary(
            commandIdentifier: "set-amp-limit", issuedAt: now.addingTimeInterval(-1),
            command: .setAmpLimit(16)
        )
        #expect(target.supportsTelemetryConfirmation)
        #expect(target.updatingConfirmation(from: current).confirmedAt == now)
        #expect(amps.updatingConfirmation(from: current).confirmedAt == now)

        current.exteriorStatus = ExteriorSnapshot(
            openings: [OpeningReading(opening: .tailgate, state: .open)],
            isLocked: true, alarmTriggered: nil, reportedAt: now
        )
        let tailgate = PendingCommandSummary(
            commandIdentifier: "open-tailgate", issuedAt: now.addingTimeInterval(-1),
            command: .openTailgate
        )
        #expect(tailgate.supportsTelemetryConfirmation)
        #expect(tailgate.updatingConfirmation(from: current).confirmedAt == now)
    }

    @Test func parkedLossRequiresContinuousFreshStationaryObservations() throws {
        let start = Date().addingTimeInterval(-3600)
        func sample(_ minutes: Double, battery: Double = 60, odometer: Int = 1000) -> VehicleState {
            let date = start.addingTimeInterval(minutes * 60)
            var current = state(at: date, odometer: odometer)
            current.energy.batteryPercentage = battery
            current.freshness.readingDates = [.battery: date, .charging: date, .odometer: date]
            return current
        }
        var detector = ParkedChargeLossDetector()
        #expect(detector.ingest(sample(0)) == nil)
        #expect(detector.ingest(sample(15)) == nil)
        let detected = detector.ingest(sample(30, battery: 58))
        let loss = try #require(detected)
        #expect(loss.kind == .parkedChargeLoss)
        #expect(loss.before == "60.0")
        #expect(loss.after == "58.0")
        #expect(loss.intervalStart == start)
        let database = VehicleDatabase.inMemory()
        database.recordActivities([loss])
        #expect(database.history.recentActivities(for: loss.vin).first == loss)
        #expect(detector.ingest(sample(30, battery: 58)) == nil)
        detector.reset()
        #expect(detector.ingest(sample(0)) == nil)
        #expect(detector.ingest(sample(30, battery: 58)) == nil)
        #expect(detector.ingest(sample(45, battery: 58, odometer: 1001)) == nil)
        #expect(detector.ingest(sample(60, battery: 57, odometer: 1001)) == nil)
        var stale = sample(75, battery: 56, odometer: 1001)
        stale.freshness.readingDates[.odometer] = start
        #expect(detector.ingest(stale) == nil)
        #expect(detector.ingest(sample(90, battery: 55, odometer: 1001)) == nil)
    }

    @Test func fleetTotalsExcludeStaleAndUnknownReadings() {
        let now = Date()
        var fresh = state(at: now)
        fresh.freshness.readingDates = [.range: now, .odometer: now, .charging: now]
        var stale = state(at: now)
        stale.energy.chargingState = .charging
        stale.freshness.readingDates = [.range: now.addingTimeInterval(-3600), .charging: now.addingTimeInterval(-3600)]
        let summary = VehicleFleetSummary(states: [fresh, stale], now: now)
        #expect(summary.rangeKm == fresh.primaryRangeKm)
        #expect(summary.odometerKm == fresh.maintenance.odometerKm)
        #expect(summary.chargingCount == 0)
        #expect(summary.chargingCoverage == 1)
        fresh.energy.chargingState = .unknown("NEW_STATE")
        #expect(VehicleFleetSummary(states: [fresh], now: now).chargingCoverage == 0)
        #expect(VehicleFleetSummary(states: [], now: now).rangeKm == nil)
    }

    @Test func airCleaningReportsOnlyPairedRunsForTheSelectedVehicle() {
        let now = Date()
        func event(_ minutes: Double, _ before: String, _ after: String, vin: String = "VIN") -> VehicleActivity {
            VehicleActivity(vin: vin, timestamp: now.addingTimeInterval(minutes * 60), kind: .airCleaning,
                            subject: "state", before: before, after: after)
        }
        let events = [event(0, "off", "on"), event(10, "on", "off"),
                      event(20, "off", "on"), event(200, "on", "off"),
                      event(210, "on", "off"), event(220, "off", "on", vin: "OTHER")]
        let cycles = HistoryInsights.airCleaningCycles(from: events.reversed(), vin: "VIN")
        #expect(cycles.count == 1)
        #expect(cycles.first?.observedMinutes == 10)
    }

    @Test func warningTransitionsRequireKnownFreshOrderedObservations() {
        let now = Date()
        var previous = state(at: now.addingTimeInterval(-60))
        previous.freshness.readingDates[.health] = previous.freshness.fetchedAt
        previous.maintenance.details = VehicleHealthDetails(tyres: [], warnings: [], reportedWarnings: [.washerFluid])
        var current = state(at: now)
        current.freshness.readingDates[.health] = now
        current.maintenance.details = VehicleHealthDetails(tyres: [], warnings: [.washerFluid], reportedWarnings: [.washerFluid])
        let events = VehicleActivity.changes(from: previous, to: current)
        #expect(events.count == 1)
        #expect(events.first?.after == "Active")
        current.maintenance.details = VehicleHealthDetails(tyres: [], warnings: [], reportedWarnings: [])
        #expect(VehicleActivity.changes(from: previous, to: current).isEmpty)
        current.freshness.readingDates[.health] = now.addingTimeInterval(-3600)
        #expect(VehicleActivity.changes(from: previous, to: current).isEmpty)
    }

    @Test func versionsAndChargingChangesAreRecordedOnceAndIsolatedByVIN() throws {
        let now = Date()
        var previous = state(at: now.addingTimeInterval(-60))
        previous.softwareInfo = VehicleSoftwareInfo(version: nil, state: .unknown, installedVersion: "4.2")
        previous.freshness.readingDates[.charging] = previous.freshness.fetchedAt
        var current = state(at: now)
        current.softwareInfo = VehicleSoftwareInfo(version: nil, state: .unknown, installedVersion: "5.1")
        current.energy.chargingState = .charging
        current.freshness.readingDates[.charging] = now
        let events = VehicleActivity.changes(from: previous, to: current)
        #expect(events.count == 2)
        #expect(VehicleActivity.changes(from: current, to: current).isEmpty)
        let database = VehicleDatabase.inMemory()
        database.recordActivities(events)
        database.recordActivities(events)
        #expect(database.history.recentActivities(for: current.identity.vin).count == 2)
        #expect(database.history.recentActivities(for: "OTHER-VIN").isEmpty)
        let version = try database.db.query(sql: "PRAGMA user_version;") { statement in
            statement.step() ? statement.columnInt64(at: 0) : nil
        }
        #expect(version == Int64(VehicleDatabase.latestSchemaVersion))
    }
}
