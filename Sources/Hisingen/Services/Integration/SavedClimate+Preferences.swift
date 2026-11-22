import Foundation

extension AutomationCommandPolicy.SavedClimate {
    /// The climate the reader saved for remote starts. Calendar preconditioning, schedules and
    /// location triggers all read it here, so they cannot drift apart.
    init(preferences: PreferencesStore) {
        self.init(
            temperatureCelsius: Float(preferences.remoteClimateTemperature),
            frontLeftSeat: preferences.remoteDriverSeatHeating,
            frontRightSeat: preferences.remoteFrontRightSeatHeating,
            rearLeftSeat: preferences.remoteRearLeftSeatHeating,
            rearRightSeat: preferences.remoteRearRightSeatHeating,
            steeringWheel: preferences.remoteSteeringWheelHeating)
    }
}
