import Foundation
import Testing
@testable import Hisingen

/// A poll that starts before a live frame can finish after it. Merging the poll over the
/// frame rolled the display back to what the vehicle reported earlier, and nothing corrected
/// it until the next change: a lock that had just engaged read unlocked. The merge now keeps
/// the held reading when both sides carry a report date and the held one is strictly newer.
@Suite("Stale poll merge")
struct StalePollMergeTests {
    private let vin = "YSMSTALEPOLL01"
    private let reported = Date(timeIntervalSince1970: 1_800_000_000)
    private let features = FeatureSelection(enabled: [.exteriorStatus, .chargingDetails])

    private func state(
        locked: Bool?, tailgateLocked: Bool? = nil, battery: Double = 50, range: Int = 200,
        charging: ChargingState = .idle, locksDate: Date? = nil, batteryDate: Date? = nil,
        chargingDate: Date? = nil
    ) -> VehicleState {
        var result = vehicle(
            vin: vin, battery: battery, rangeKm: range, state: charging,
            exteriorStatus: ExteriorSnapshot(
                openings: [], isLocked: locked, alarmTriggered: false, isTailgateLocked: tailgateLocked))
        if let locksDate { result.freshness.readingDates[.locks] = locksDate }
        if let batteryDate {
            result.freshness.readingDates[.battery] = batteryDate
            result.freshness.readingDates[.range] = batteryDate
        }
        if let chargingDate { result.freshness.readingDates[.charging] = chargingDate }
        return result
    }

    private func merged(poll: VehicleState, over held: VehicleState) -> VehicleState {
        poll.mergingLastKnown(from: held, features: features)
    }

    @Test("An older poll does not unlock a car a newer frame reported locked")
    func olderPollKeepsTheNewerLock() {
        let held = state(locked: true, locksDate: reported.addingTimeInterval(10))
        let poll = state(locked: false, locksDate: reported)

        let result = merged(poll: poll, over: held)

        #expect(result.exteriorStatus?.isLocked == true)
        #expect(result.reportedDate(for: .locks) == reported.addingTimeInterval(10))
    }

    @Test("A poll the vehicle reported later than the held reading wins")
    func newerPollReplacesTheHeldLock() {
        let held = state(locked: true, locksDate: reported)
        let poll = state(locked: false, locksDate: reported.addingTimeInterval(10))

        let result = merged(poll: poll, over: held)

        #expect(result.exteriorStatus?.isLocked == false)
        #expect(result.reportedDate(for: .locks) == reported.addingTimeInterval(10))
    }

    @Test("Equal report dates take the incoming reading")
    func equalDatesTakeTheIncomingReading() {
        let held = state(locked: true, locksDate: reported)
        let poll = state(locked: false, locksDate: reported)

        #expect(merged(poll: poll, over: held).exteriorStatus?.isLocked == false)
    }

    @Test("Without a report date on the poll the incoming reading is used, as before")
    func missingPollDateTakesTheIncomingReading() {
        let held = state(locked: true, locksDate: reported.addingTimeInterval(10))
        let poll = state(locked: false)

        #expect(merged(poll: poll, over: held).exteriorStatus?.isLocked == false)
    }

    @Test("Without a report date on the held reading the incoming reading is used, as before")
    func missingHeldDateTakesTheIncomingReading() {
        let held = state(locked: true)
        let poll = state(locked: false, locksDate: reported)

        #expect(merged(poll: poll, over: held).exteriorStatus?.isLocked == false)
    }

    @Test("Keeping the lock does not hold back a tailgate lock the poll reports newer")
    func lockAndOpeningsAreComparedSeparately() {
        var held = state(locked: true, tailgateLocked: true, locksDate: reported.addingTimeInterval(10))
        held.freshness.readingDates[.openings] = reported.addingTimeInterval(-10)
        var poll = state(locked: false, tailgateLocked: false, locksDate: reported)
        poll.freshness.readingDates[.openings] = reported

        let result = merged(poll: poll, over: held)

        #expect(result.exteriorStatus?.isLocked == true)
        #expect(result.exteriorStatus?.isTailgateLocked == false)
    }

    @Test("An older poll does not roll battery, range and charging state back")
    func olderPollKeepsTheNewerChargingReadings() {
        let held = state(
            locked: nil, battery: 61, range: 230, charging: .charging,
            batteryDate: reported.addingTimeInterval(10), chargingDate: reported.addingTimeInterval(10))
        let poll = state(
            locked: nil, battery: 58, range: 218, charging: .idle,
            batteryDate: reported, chargingDate: reported)

        let result = merged(poll: poll, over: held)

        #expect(result.energy.batteryPercentage == 61)
        #expect(result.energy.rangeKm == 230)
        #expect(result.energy.chargingState == .charging)
        #expect(result.reportedDate(for: .battery) == reported.addingTimeInterval(10))
    }

    @Test("A newer poll still updates battery, range and charging state")
    func newerPollUpdatesTheChargingReadings() {
        let held = state(
            locked: nil, battery: 58, range: 218, charging: .idle,
            batteryDate: reported, chargingDate: reported)
        let poll = state(
            locked: nil, battery: 61, range: 230, charging: .charging,
            batteryDate: reported.addingTimeInterval(10), chargingDate: reported.addingTimeInterval(10))

        let result = merged(poll: poll, over: held)

        #expect(result.energy.batteryPercentage == 61)
        #expect(result.energy.rangeKm == 230)
        #expect(result.energy.chargingState == .charging)
    }
}
