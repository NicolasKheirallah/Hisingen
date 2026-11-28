import Foundation

/// One action the reader attached to the car arriving at, or leaving, a saved charge location.
///
/// The comparison happens inside Hisingen: the vehicle already reports its position with the
/// rest of its telemetry, and the saved locations already carry coordinates the app decoded.
/// Nothing here asks macOS for Location Services, so a trigger works the moment the car's next
/// snapshot lands and never shows a permission prompt the reader did not expect from a
/// menu-bar app.
struct LocationTrigger: Codable, Equatable, Identifiable, Sendable {
    enum Event: String, Codable, CaseIterable, Sendable {
        case arrival
        case departure
    }

    var id: UUID
    var event: Event
    /// The saved charge location this trigger watches. `nil` watches every saved location.
    var locationID: String?
    var command: RemoteCommand
    var isEnabled: Bool
    /// Optional target VIN; `nil` applies to whichever vehicle experienced the location change.
    var targetVIN: String? = nil

    init(id: UUID = UUID(), event: Event, locationID: String? = nil,
         command: RemoteCommand, isEnabled: Bool = true, targetVIN: String? = nil) {
        self.id = id
        self.event = event
        self.locationID = locationID
        self.command = command
        self.isEnabled = isEnabled
        let normalized = targetVIN?.normalizedVIN
        self.targetVIN = (normalized?.isEmpty == false) ? normalized : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, event, locationID, command, isEnabled, targetVIN
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            event: try c.decode(Event.self, forKey: .event),
            locationID: try c.decodeIfPresent(String.self, forKey: .locationID),
            command: try c.decode(RemoteCommand.self, forKey: .command),
            isEnabled: try c.decode(Bool.self, forKey: .isEnabled),
            targetVIN: try c.decodeIfPresent(String.self, forKey: .targetVIN)
        )
    }

    /// Whether this trigger fires for `vin`.
    func applies(to vin: String) -> Bool {
        guard let targetVIN, !targetVIN.isEmpty else { return true }
        return targetVIN.normalizedVIN == vin.normalizedVIN
    }

    /// Whether this trigger applies to a location, given that `nil` means every saved one.
    func watches(locationID: String) -> Bool {
        guard let watched = self.locationID, !watched.isEmpty else { return true }
        return watched == locationID
    }

    var isRunnable: Bool { isEnabled && AutomationCommandPolicy.allows(command) }
}
