import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PanelPresentationTests {
    @Test func upcomingOmitsAnExpiredTimerTheCarStillMarksActive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = vehicle()
        state.climateTimers = [3_600.0, -3_600.0, 120.0].map { offset in
            VehicleSchedule(backendID: String(offset), kind: .climate, startHour: 5, startMinute: 0,
                            endHour: nil, endMinute: nil, isActive: true, oneShotDate: now + offset)
        }

        let upcoming = PlanTimeline.entries(for: state, now: now)

        #expect(upcoming.map(\.next) == [now + 120, now + 3_600])
    }

    @Test func aGlobalChargingWindowRepeatsDailyWithoutWeekdays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let morning = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 18, hour: 8
        )))
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 7, startMinute: 30,
            endHour: 10, endMinute: 0, weekdays: [], isActive: true
        )
        let tomorrow = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 19, hour: 7, minute: 30
        )))

        #expect(schedule.validationMessage(expectedKind: .globalCharging) == nil)
        #expect(PlanTimeline.nextStart(of: schedule, after: morning, calendar: calendar) == tomorrow)
    }

    @Test func chargeTraceDoesNotMoveOutOfWindowReadingsOntoTheBoundary() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let window = start...(start + 3_600)
        func session(_ id: String, from: TimeInterval, to: TimeInterval?) -> HistoricalChargingSession {
            HistoricalChargingSession(id: id, vin: "TEST", startedAt: start + from,
                                      endedAt: to.map { start + $0 }, startSoc: 22, endSoc: to.map { _ in 80 },
                                      energyDeliveredKwh: 29, peakPowerKw: 11, averagePowerKw: 8,
                                      locationName: nil, createdAt: start)
        }

        let visible = EnergyTrace.charges([
            session("within", from: 120, to: 200),
            session("crosses start", from: -120, to: 120),
            session("crosses end", from: 3_500, to: 3_700),
            session("still charging", from: 240, to: nil)
        ], in: window)

        #expect(visible.count == 1)
        #expect(visible.first?.start == start + 120)
        #expect(visible.first?.end == start + 200)
    }
}
