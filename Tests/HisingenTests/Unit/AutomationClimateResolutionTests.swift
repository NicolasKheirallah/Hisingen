import Foundation
import Testing
@testable import Hisingen

/// A schedule or a trigger stores a neutral climate start. It must send the climate settings the
/// reader saved, and leave a command that already names its own settings alone.
@MainActor
struct AutomationClimateResolutionTests {
    private let saved = AutomationCommandPolicy.SavedClimate(
        temperatureCelsius: 21.5,
        frontLeftSeat: .level3, frontRightSeat: .off,
        rearLeftSeat: .off, rearRightSeat: .off,
        steeringWheel: .level1)

    private var template: RemoteCommand {
        AutomationCommandPolicy.choices().first {
            if case .startClimate = $0 { return true }
            return false
        } ?? .stopClimate
    }

    @Test
    func theNeutralTemplateBecomesTheSavedSettings() {
        let resolved = AutomationCommandPolicy.resolved(template, saved: saved)

        #expect(resolved == .startClimate(
            temperatureCelsius: 21.5,
            frontLeftSeat: .level3, frontRightSeat: .off,
            rearLeftSeat: .off, rearRightSeat: .off,
            steeringWheel: .level1))
    }

    @Test
    func aCommandThatNamesItsOwnSettingsIsSentUnchanged() {
        let own = RemoteCommand.startClimate(
            temperatureCelsius: 18, frontLeftSeat: .unspecified, frontRightSeat: .unspecified,
            rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified)
        let heated = RemoteCommand.startClimate(
            temperatureCelsius: 0, frontLeftSeat: .level1, frontRightSeat: .unspecified,
            rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified)

        #expect(AutomationCommandPolicy.resolved(own, saved: saved) == own)
        #expect(AutomationCommandPolicy.resolved(heated, saved: saved) == heated)
    }

    @Test
    func otherCommandsPassThrough() {
        #expect(AutomationCommandPolicy.resolved(.lock, saved: saved) == .lock)
        #expect(AutomationCommandPolicy.resolved(.stopClimate, saved: saved) == .stopClimate)
    }
    @Test
    func theSavedSettingsAreReadFromThePreferencesTheCalendarAlsoUses() {
        let scoped = ScopedPreferences(label: "saved-climate")
        let preferences = scoped.store
        preferences.remoteClimateTemperature = 19
        preferences.remoteDriverSeatHeating = .level2
        preferences.remoteFrontRightSeatHeating = .off
        preferences.remoteRearLeftSeatHeating = .off
        preferences.remoteRearRightSeatHeating = .off
        preferences.remoteSteeringWheelHeating = .level1

        let fromPreferences = AutomationCommandPolicy.SavedClimate(preferences: preferences)

        #expect(fromPreferences.startCommand == .startClimate(
            temperatureCelsius: 19,
            frontLeftSeat: .level2, frontRightSeat: .off,
            rearLeftSeat: .off, rearRightSeat: .off,
            steeringWheel: .level1))
        #expect(AutomationCommandPolicy.resolved(template, saved: fromPreferences)
                == fromPreferences.startCommand)
    }
}
