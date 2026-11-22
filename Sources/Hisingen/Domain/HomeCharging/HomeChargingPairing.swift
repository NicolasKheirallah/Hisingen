import Foundation

/// The explicit link between one Home Assistant charger and one Hisingen vehicle.
///
/// Nothing infers this. A charger that happens to be near the car, or one several cars use, is
/// not evidence about which car drew the energy; the reader names the vehicle once, here, and
/// says whether the charger is shared. Session attribution and every vehicle-specific automatic
/// plan read this value and nothing else.
struct HomeChargingPairing: Codable, Equatable, Sendable {
    var baseURL: String
    /// The charger's stable identity in Home Assistant (for NexBlue, the device serial number).
    var chargerID: String
    var chargerName: String
    /// The vendor's role for this account at pairing time. NexBlue allows only the owner to read
    /// or write a schedule; `nil` on pairings saved before the role was stored, and for vendors
    /// that do not report one.
    var chargerRole: Int?
    var entities: HomeChargerEntityMap
    var vin: String
    /// The saved Hisingen charge location this charger stands at, when the vehicle has one.
    var locationID: String?
    var locationAlias: String
    /// Another vehicle may also use this charger. A shared charger never attributes a session on
    /// its own: it needs the paired vehicle's own charging to overlap in time.
    var isSharedCharger: Bool
    /// The home's time zone as Home Assistant reports it. Deadlines and plan windows are shown in it.
    var timeZoneIdentifier: String
    /// Key of the Tibber home in `tibber.get_prices` responses. `nil` takes the first home.
    var tibberHome: String?
    /// Variable network fee (öre/kWh) that Tibber's all-in price leaves out. Zero when the
    /// reader has not set one, and recorded as an assumption on every priced session.
    var networkFeeOrePerKwh: Double
    var pairedAt: Date
    /// Optional on disk so a pairing saved before direct chargers existed still decodes, as Home
    /// Assistant. Read it through `source`.
    private var chargerSource: ChargerSource?

    /// Where the charger's readings come from. A direct charger has no Home Assistant address or
    /// entity map; both stay empty for it.
    var source: ChargerSource { chargerSource ?? .homeAssistant }

    init(baseURL: String, chargerID: String, chargerName: String, entities: HomeChargerEntityMap,
         vin: String, locationID: String?, locationAlias: String, isSharedCharger: Bool = false,
         timeZoneIdentifier: String = TimeZone.current.identifier, tibberHome: String? = nil,
         networkFeeOrePerKwh: Double = 0, pairedAt: Date = Date(), source: ChargerSource = .homeAssistant,
         chargerRole: Int? = nil) {
        self.chargerSource = source == .homeAssistant ? nil : source
        self.baseURL = baseURL
        self.chargerID = chargerID
        self.chargerName = chargerName
        self.chargerRole = chargerRole
        self.entities = entities
        self.vin = vin
        self.locationID = locationID
        self.locationAlias = locationAlias
        self.isSharedCharger = isSharedCharger
        self.timeZoneIdentifier = timeZoneIdentifier
        self.tibberHome = tibberHome
        self.networkFeeOrePerKwh = networkFeeOrePerKwh
        self.pairedAt = pairedAt
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// Stable identity for one charger on one vehicle: the source, the charger's own id in that
    /// service, and the VIN. Two chargers of one vendor differ by `chargerID`; the same charger
    /// paired to a second car is a second pairing, because session attribution is per vehicle.
    /// Computed rather than stored so pairings saved before a second charger existed keep decoding.
    var identity: String {
        "\(source.rawValue)|\(chargerID)|\(vin.normalizedVIN)"
    }

    /// Whether this pairing is the one described by `other` – same charger, same vehicle.
    func isSameCharger(as other: HomeChargingPairing) -> Bool {
        identity == other.identity
    }

    /// Whether the account may read or write this charger's schedule. NexBlue allows only the
    /// owner. A pairing saved before the role was stored carries no role and keeps the control;
    /// the provider still refuses a non-owner when the schedule is read.
    var canControlSchedule: Bool { chargerRole.map { $0 == 0 } ?? true }

    func isPaired(toVehicle otherVIN: String) -> Bool {
        !vin.isEmpty && vin.caseInsensitiveCompare(otherVIN) == .orderedSame
    }

    /// Whether the vehicle is parked at the saved location the charger belongs to. This decides
    /// where the card appears, never which vehicle a session belongs to.
    func isAtPairedLocation(_ presence: ChargeLocationPresence?) -> Bool {
        guard let locationID, let presence else { return false }
        return presence.locationID == locationID
    }
}

/// A stored Home Assistant address, validated. Local installs are plain `http`, so both schemes
/// are accepted; the path is dropped because the API lives at the root.
enum HomeAssistantAddress {
    enum Failure: Error, Equatable {
        case empty
        case unsupportedScheme
        case malformed
    }

    static func normalise(_ text: String) -> Result<URL, Failure> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else {
            return .failure(.malformed)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedScheme)
        }
        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { return .failure(.malformed) }
        return .success(url)
    }
}
