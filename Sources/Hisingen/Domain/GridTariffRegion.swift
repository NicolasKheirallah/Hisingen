import Foundation

/// The country whose grid operator bills the transfer fee on top of Tibber's price.
///
/// The grid tariff is a separate contract with a different company in every market, and the shapes
/// differ: Sweden and Norway bill a rate per kWh plus a fixed yearly fee that follows the main fuse,
/// Germany bills a working price plus a fixed yearly price, and the Netherlands bills a capacity fee
/// with no per-kWh part for households at all.
///
/// Only Sweden ships published rates today. Every other market offers the custom path and says so,
/// because a guessed grid fee would put a wrong number in every cost the app shows. Adding a market
/// means adding its rates, not adding a case here.
enum GridTariffRegion: String, Codable, CaseIterable, Sendable, Identifiable {
    case sweden
    case norway
    case denmark
    case germany
    case netherlands

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sweden: return L10n.text("Sweden")
        case .norway: return L10n.text("Norway")
        case .denmark: return L10n.text("Denmark")
        case .germany: return L10n.text("Germany")
        case .netherlands: return L10n.text("Netherlands")
        }
    }

    /// Every market Tibber sells electricity in keeps Central European Time, so a high-load window
    /// starts at the same wall clock in all of them. The calendar is still asked per region so a
    /// market outside CET needs no change to the pricing maths.
    var timeZoneIdentifier: String {
        switch self {
        case .sweden: return "Europe/Stockholm"
        case .norway: return "Europe/Oslo"
        case .denmark: return "Europe/Copenhagen"
        case .germany: return "Europe/Berlin"
        case .netherlands: return "Europe/Amsterdam"
        }
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    /// The hundredth of a currency unit the fee is printed in on the invoice. The stored rate is
    /// always hundredths per kWh: öre in Sweden and Norway, øre in Denmark, cent in Germany and
    /// the Netherlands.
    var feeUnitWord: String {
        switch self {
        case .sweden: return "öre"
        case .norway: return "øre"
        case .denmark: return "øre"
        case .germany, .netherlands: return "ct"
        }
    }

    var currencySymbol: String {
        switch self {
        case .sweden, .norway, .denmark: return "kr"
        case .germany, .netherlands: return "€"
        }
    }

    /// Whether this build carries published rates for the market. Sweden does; a market without
    /// them still offers the flat and custom paths, and says where to copy the real figures from.
    var hasPublishedRates: Bool { self == .sweden }

    /// The market named by a Tibber home's time zone, when it is one this build knows.
    static func matching(timeZoneIdentifier: String?) -> GridTariffRegion? {
        guard let timeZoneIdentifier else { return nil }
        return allCases.first { $0.timeZoneIdentifier == timeZoneIdentifier }
    }
}
