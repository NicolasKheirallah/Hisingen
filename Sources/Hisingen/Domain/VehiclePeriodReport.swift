import Foundation

/// One trip as a report shows it: when, how far, how much energy the car's own consumption figure
/// implies, and what that energy cost at the report's price.
struct PeriodReportTrip: Equatable, Sendable {
    let endedAt: Date
    let distanceKm: Double
    let energyKwh: Double?
    let cost: Double?
    /// True when the price came from the fixed tariff because the window had no market series.
    let priceUsedFallback: Bool
}

/// One charging session as a report shows it. The cost is the session's own resolved cost under
/// the rate policy, so it matches the figure the charging row in History already displays.
struct PeriodReportCharge: Equatable, Sendable {
    let startedAt: Date
    let energyKwh: Double
    let cost: Double?
}

/// The plain values a period report is built from. The History card and the recurring-report
/// scheduler both fill this from the same loader, so a weekly notification and a printed report
/// cannot disagree about the week they describe.
struct PeriodReportInput: Equatable, Sendable {
    var vehicleName: String
    var vin: String
    var period: ReportPeriod
    var trips: [PeriodReportTrip]
    var charges: [PeriodReportCharge]
    var maintenance: [MaintenanceEntry]
    var odometerStartKm: Int?
    var odometerEndKm: Int?
    var depreciation: DepreciationFigure?
    /// The stated assumption the depreciation figures come from, already worded for printing.
    var depreciationBasis: String?
    var currencySymbol: String
    var distanceUnit: DistanceUnit
    var generatedAt: Date
    var redacted: Bool

    var distanceKm: Double { trips.reduce(0) { $0 + $1.distanceKm } }
    var tripEnergyKwh: Double { trips.compactMap(\.energyKwh).reduce(0, +) }
    var tripCost: Double { trips.compactMap(\.cost).reduce(0, +) }
    var tripCostCoverage: Int { trips.filter { $0.cost != nil }.count }
    var chargingEnergyKwh: Double { charges.reduce(0) { $0 + $1.energyKwh } }
    var chargingCost: Double { charges.compactMap(\.cost).reduce(0, +) }
    var chargingCostCoverage: Int { charges.filter { $0.cost != nil }.count }
    var maintenanceCost: Double { maintenance.compactMap(\.cost).reduce(0, +) }
    var odometerKm: Int? {
        guard let start = odometerStartKm, let end = odometerEndKm, end >= start else { return nil }
        return end - start
    }

    var isEmpty: Bool {
        trips.isEmpty && charges.isEmpty && maintenance.isEmpty
    }
}

/// Writes a period report as text for copying or as CSV for a spreadsheet. Both formats carry the
/// same rows from the same input; the text one is localized, the CSV keeps technical English
/// column names like every other export in the app.
enum VehiclePeriodReport {
    // MARK: - Text

    static func text(_ input: PeriodReportInput) -> String {
        var lines: [String] = []
        func row(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(key): \(value)")
        }
        func heading(_ title: String) {
            lines.append("")
            lines.append(title.uppercased(with: L10n.displayLocale))
            lines.append(String(repeating: "-", count: max(12, title.count)))
        }

        lines.append(L10n.text("Period Report"))
        lines.append(String(repeating: "=", count: 44))
        row(L10n.text("Vehicle"), input.vehicleName)
        row(L10n.text("VIN"), input.redacted
            ? VehicleReportBuilder.maskedVIN(input.vin) : input.vin)
        row(L10n.text("Period"), L10n.format("%@ (%@)", input.period.titleText(), input.period.cadence.title))
        row(L10n.text("Generated"), Format.dateTimeFormatter.string(from: input.generatedAt))

        heading(L10n.text("Totals"))
        row(L10n.text("Distance"), Format.distance(km: input.distanceKm, decimals: 1, unit: input.distanceUnit))
        if let odometer = input.odometerKm {
            row(L10n.text("Odometer Covered"), Format.distance(km: odometer, grouped: true, unit: input.distanceUnit))
        }
        row(L10n.text("Energy Used"), Format.energyKwh(input.chargingEnergyKwh))
        row(L10n.text("Trips"), "\(input.trips.count)")
        row(L10n.text("Charges"), "\(input.charges.count)")
        row(L10n.text("Estimated Trip Cost"),
            input.tripCostCoverage > 0 ? Format.currency(input.tripCost, symbol: input.currencySymbol) : nil)
        row(L10n.text("Charging Cost"),
            input.chargingCostCoverage > 0 ? Format.currency(input.chargingCost, symbol: input.currencySymbol) : nil)
        row(L10n.text("Maintenance"), input.maintenance.isEmpty ? nil
            : Format.currency(input.maintenanceCost, symbol: input.currencySymbol))

        if let depreciation = input.depreciation {
            heading(L10n.text("Depreciation"))
            row(L10n.text("Value at Start"), Format.currency(depreciation.valueAtStart, symbol: input.currencySymbol, decimals: 0))
            row(L10n.text("Value at End"), Format.currency(depreciation.valueAtEnd, symbol: input.currencySymbol, decimals: 0))
            row(L10n.text("Loss in Period"), Format.currency(depreciation.periodLoss, symbol: input.currencySymbol, decimals: 0))
            if let basis = input.depreciationBasis, !basis.isEmpty {
                lines.append(basis)
            }
        }

        heading(L10n.text("Trips"))
        if input.trips.isEmpty {
            lines.append(L10n.text("No trips in this period."))
        } else {
            for trip in input.trips {
                lines.append(tripLine(trip, input: input))
            }
        }

        heading(L10n.text("Charging"))
        if input.charges.isEmpty {
            lines.append(L10n.text("No charging sessions in this period."))
        } else {
            for charge in input.charges {
                lines.append(chargeLine(charge, input: input))
            }
        }

        heading(L10n.text("Maintenance Log"))
        if input.maintenance.isEmpty {
            lines.append(L10n.text("No maintenance entries in this period."))
        } else {
            for entry in input.maintenance {
                lines.append(maintenanceLine(entry, input: input))
            }
        }

        lines.append("")
        lines.append(L10n.text("Costs are estimates from your electricity rate; depreciation is arithmetic on the figures you entered."))
        return lines.joined(separator: "\n")
    }

    // MARK: - CSV

    /// Technical column names, like every other CSV this app writes: a spreadsheet column is a
    /// machine contract, not prose.
    static var csvHeader: String {
        ["Type", "Date", "Distance (km)", "Energy (kWh)", "Cost", "Currency",
         "Kind", "Title", "Odometer (km)"].joined(separator: ",")
    }

    static func csv(_ input: PeriodReportInput) -> String {
        var rows: [String] = [csvHeader]
        for trip in input.trips {
            rows.append(csvRow([
                "trip",
                Format.iso8601.string(from: trip.endedAt),
                csvNumber(trip.distanceKm, 2),
                csvNumber(trip.energyKwh, 2),
                csvNumber(trip.cost, 2),
                input.currencySymbol,
                "", "", ""
            ]))
        }
        for charge in input.charges {
            rows.append(csvRow([
                "charging",
                Format.iso8601.string(from: charge.startedAt),
                "",
                csvNumber(charge.energyKwh, 2),
                csvNumber(charge.cost, 2),
                input.currencySymbol,
                "", "", ""
            ]))
        }
        for entry in input.maintenance {
            rows.append(csvRow([
                "maintenance",
                Format.iso8601.string(from: entry.date),
                "",
                "",
                csvNumber(entry.cost, 2),
                input.currencySymbol,
                entry.kind.rawValue,
                entry.title,
                entry.odometerKm.map(String.init) ?? ""
            ]))
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Notification summary

    /// The one line a recurring report puts in a banner: the three figures a reader acts on.
    static func summaryText(_ input: PeriodReportInput) -> String {
        L10n.format(
            "%@ driven · %@ energy used · %@ estimated cost",
            Format.distance(km: input.distanceKm, decimals: 0, unit: input.distanceUnit),
            Format.energyKwh(input.chargingEnergyKwh),
            Format.currency(input.tripCost + input.chargingCost, symbol: input.currencySymbol)
        )
    }

    static func fileName(_ input: PeriodReportInput) -> String {
        let stamp = Format.iso8601.string(from: input.period.start)
            .replacingOccurrences(of: ":", with: "-")
        return "hisingen-report-\(stamp).txt"
    }

    // MARK: - Rows

    private static func tripLine(_ trip: PeriodReportTrip, input: PeriodReportInput) -> String {
        var parts = [Format.shortDate(date: trip.endedAt),
                     Format.distance(km: trip.distanceKm, decimals: 1, unit: input.distanceUnit)]
        if let energy = trip.energyKwh { parts.append(Format.energyKwh(energy)) }
        if let cost = trip.cost {
            parts.append(Format.currency(cost, symbol: input.currencySymbol))
        }
        return "• " + parts.joined(separator: " · ")
    }

    private static func chargeLine(_ charge: PeriodReportCharge, input: PeriodReportInput) -> String {
        var parts = [Format.shortDate(date: charge.startedAt), Format.energyKwh(charge.energyKwh)]
        if let cost = charge.cost {
            parts.append(Format.currency(cost, symbol: input.currencySymbol))
        }
        return "• " + parts.joined(separator: " · ")
    }

    private static func maintenanceLine(_ entry: MaintenanceEntry, input: PeriodReportInput) -> String {
        var parts = [Format.shortDate(date: entry.date), entry.kind.title, entry.title]
        if let odometer = entry.odometerKm {
            parts.append(Format.distance(km: odometer, grouped: true, unit: input.distanceUnit))
        }
        if let cost = entry.cost {
            parts.append(Format.currency(cost, symbol: input.currencySymbol))
        }
        return "• " + parts.joined(separator: " · ")
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map { CSV.field($0) }.joined(separator: ",")
    }

    private static func csvNumber(_ value: Double?, _ places: Int) -> String {
        guard let value else { return "" }
        return HistoryCSVRows.posix(value, places)
    }
}
