import Foundation

/// What the reader says their car costs to own, so a report can show a depreciation figure that
/// is arithmetic on their own numbers rather than a market estimate Hisingen has no basis for.
///
/// Hisingen never guesses a resale value: it cannot see this car's condition, market or mileage
/// history well enough to price it. What it can do is apply the reader's stated annual decline to
/// the price they paid, and say so on the report.
struct DepreciationAssumption: Codable, Equatable, Sendable {
    var purchasePrice: Double
    var purchaseDate: Date
    /// Percent of the remaining value lost per year, declining balance.
    var annualDeclinePercent: Double

    /// The largest annual decline the model accepts. Above this the arithmetic stops describing a
    /// car and starts producing a number nobody believes.
    static let maximumAnnualDeclinePercent: Double = 50

    init(purchasePrice: Double, purchaseDate: Date, annualDeclinePercent: Double) {
        self.purchasePrice = purchasePrice
        self.purchaseDate = purchaseDate
        self.annualDeclinePercent = annualDeclinePercent
    }

    /// A stored assumption can carry anything a hand-edited defaults file wrote; every reader
    /// goes through this rather than trusting the decoded fields.
    var sanitized: DepreciationAssumption {
        DepreciationAssumption(
            purchasePrice: purchasePrice.isFinite ? max(0, purchasePrice) : 0,
            purchaseDate: purchaseDate,
            annualDeclinePercent: annualDeclinePercent.isFinite
                ? min(max(0, annualDeclinePercent), Self.maximumAnnualDeclinePercent)
                : 0
        )
    }

    /// Whether the assumption can produce a figure at all. A price of zero is the reader saying
    /// they have not filled it in, not a car worth nothing.
    var isUsable: Bool {
        let clean = sanitized
        return clean.purchasePrice > 0 && clean.annualDeclinePercent > 0
    }
}

/// The depreciation a report shows for one window: the value at each edge of the window and the
/// loss between them. Nil-safe by construction: a report with no usable assumption carries no
/// depreciation block rather than a zero that reads as "this car did not lose value".
struct DepreciationFigure: Equatable, Sendable {
    let valueAtStart: Double
    let valueAtEnd: Double
    /// Years from the purchase date to the window's end, for the report's "since" wording.
    let yearsOwned: Double

    var periodLoss: Double { max(0, valueAtStart - valueAtEnd) }
}

enum Depreciation {
    /// Declining balance: the reader's price loses `annualDeclinePercent` of what is left each
    /// year. Before the purchase date the value is the price itself; no negative years compound.
    static func value(assumption: DepreciationAssumption, at date: Date) -> Double? {
        let clean = assumption.sanitized
        guard clean.purchasePrice > 0 else { return nil }
        guard clean.annualDeclinePercent > 0 else { return clean.purchasePrice }
        let years = max(0, date.timeIntervalSince(clean.purchaseDate)) / (365.25 * 24 * 3_600)
        let retained = pow(1 - clean.annualDeclinePercent / 100, years)
        return max(0, clean.purchasePrice * retained)
    }

    static func figure(assumption: DepreciationAssumption, periodStart: Date, periodEnd: Date) -> DepreciationFigure? {
        let clean = assumption.sanitized
        guard clean.isUsable,
              let start = value(assumption: clean, at: periodStart),
              let end = value(assumption: clean, at: periodEnd) else { return nil }
        let years = max(0, periodEnd.timeIntervalSince(clean.purchaseDate)) / (365.25 * 24 * 3_600)
        return DepreciationFigure(valueAtStart: start, valueAtEnd: end, yearsOwned: years)
    }

    /// The sentence a report prints under the depreciation figures. It names the price, the date
    /// and the rate the reader entered, so the number can be checked rather than trusted.
    static func basisText(assumption: DepreciationAssumption, currencySymbol: String) -> String {
        let clean = assumption.sanitized
        guard clean.isUsable else { return "" }
        return L10n.format(
            "Assumes %@ a year from %@ paid on %@. Hisingen does not estimate a market value.",
            Format.percent(clean.annualDeclinePercent),
            Format.currency(clean.purchasePrice, symbol: currencySymbol, decimals: 0),
            Format.shortDate(date: clean.purchaseDate)
        )
    }

    /// The one line the ownership editor shows when the reader has entered nothing yet.
    static var emptyHint: String {
        L10n.text("Enter what you paid and how fast the car loses value. Depreciation is arithmetic on that, not a market estimate.")
    }
}
