import AppIntents
import Foundation

/// Returns where the vehicle was last reported, with a one-tap map link in Shortcuts output.
/// Uses only the locally cached snapshot; it never wakes the car or hits the location API,
/// so running it repeatedly costs nothing and reveals nothing fresher than Hisingen holds.
struct WhereIsMyCarIntent: AppIntent {
    static let title: LocalizedStringResource = "Where Is My Car"
    static let description = IntentDescription("Returns the last reported parking position of the active vehicle.")
    static let openAppWhenRun = false

    @Parameter(title: "Vehicle", description: "Vehicle nickname or VIN (optional)")
    var vehicle: String?

    @MainActor
    func perform() async throws -> some ProvidesDialog & ReturnsValue<String> {
        guard let (state, preferences) = AutomationHandoff.snapshot(for: vehicle),
              let lat = state.location?.latitude, let lon = state.location?.longitude else {
            return .result(value: L10n.text("unknown"),
                           dialog: IntentDialog(stringLiteral: L10n.text("No location has been reported for this vehicle yet.")))
        }
        let when = state.location?.timestamp.map { Format.relativeAge(since: $0) } ?? L10n.text("unknown time")
        let nick = preferences.vehicleNickname(for: state.identity.vin)
        let name = nick.isEmpty ? (state.identity.modelName ?? L10n.text("Vehicle")) : nick
        // Coordinates stay String(format:)-formatted: a localized decimal separator inside
        // a lat/lon pair would break paste-into-maps.
        let response = L10n.format("%@: %@, reported %@.",
                                   name,
                                   String(format: "%.5f, %.5f", lat, lon),
                                   when)
        let mapsURL = MapLinks.appleMapsPin(latitude: lat, longitude: lon)?.absoluteString ?? ""
        return .result(value: L10n.format("%@ Map: %@", response, mapsURL),
                       dialog: IntentDialog(stringLiteral: response))
    }
}
