import Foundation

/// Turns the CSV an export already builds into a workbook with the same rows plus a summary
/// sheet. Reading the CSV rather than rebuilding each dataset is deliberate: the spreadsheet and
/// the CSV cannot disagree about a value, and a dataset added to the export menu gains a workbook
/// without a second row-building path.
enum HistoryWorkbook {
    struct Table: Equatable, Sendable {
        var title: String
        var header: [String]
        var rows: [[String]]
    }

    /// Columns whose CSV cells are numbers. Identifiers stay text so leading zeros survive, and
    /// booleans and dates stay text because they are not quantities to sum.
    static let numericHeaders: Set<String> = [
        "Duration (min)", "Distance (km)", "Average Consumption", "Ambient Temperature (C)",
        "Start Latitude", "Start Longitude", "End Latitude", "End Longitude",
        "Start SoC (%)", "End SoC (%)", "Estimated Energy Added (kWh)", "Observed Peak Power (kW)",
        "Sample Average Power (kW)", "Sample Coverage", "Usable Capacity (kWh)", "Day Tariff",
        "Night Tariff", "Night Start Hour", "Night End Hour", "Estimated Cost", "Target SoC",
        "Summary Version",
        "Charger Energy (kWh)", "Charger Cost", "Charger Average Price (per kWh)",
        "Missing Price Energy (kWh)",
        "Odometer (km)", "Calculated State of Health (%)", "Calculated Degradation (%)",
        "Estimated Usable (kWh)",
        "Air Quality Index", "PM2.5", "PM10", "Filter Remaining (%)",
        "Trip Manual (km)", "Trip Automatic (km)",
        "Duration (ms)",
        "Litres", "Price per Litre", "Total",
        "Interior (C)", "Requested Setpoint (C)",
        "SOC (%)", "Power (kW)", "Voltage (V)", "Current (A)"
    ]

    /// Columns a summary may total, and only when every row carries a number: a total over the
    /// rows that happen to have a charger measurement would read as the whole dataset's figure.
    static let summedHeaders = [
        "Distance (km)", "Duration (min)", "Charger Energy (kWh)",
        "Estimated Energy Added (kWh)", "Litres"
    ]

    static func table(csv: String, title: String) -> Table? {
        let parsed = parseCSV(csv)
        guard let header = parsed.first, !header.isEmpty else { return nil }
        let rows = parsed.dropFirst().map { row -> [String] in
            if row.count >= header.count { return Array(row.prefix(header.count)) }
            return row + Array(repeating: "", count: header.count - row.count)
        }.filter { row in row.contains { !$0.isEmpty } }
        return Table(title: title, header: header, rows: rows)
    }

    static func workbook(csv: String, title: String, vehicle: String, scope: String,
                         generatedAt: Date = Date()) -> XLSXWorkbook? {
        guard let table = table(csv: csv, title: title) else { return nil }
        return workbook(table: table, vehicle: vehicle, scope: scope, generatedAt: generatedAt)
    }

    static func workbook(table: Table, vehicle: String, scope: String,
                         generatedAt: Date = Date()) -> XLSXWorkbook {
        let dataRows = [table.header.map(XLSXCell.text)] + table.rows.map { row in
            row.enumerated().map { index, value in
                typedCell(value, header: table.header[index])
            }
        }
        let summaryRows = summary(for: table, vehicle: vehicle, scope: scope, generatedAt: generatedAt)
        return XLSXWorkbook(sheets: [
            XLSXWorkbook.Sheet(name: table.title, rows: dataRows),
            XLSXWorkbook.Sheet(name: L10n.text("Summary"), rows: summaryRows)
        ])
    }

    static func typedCell(_ value: String, header: String) -> XLSXCell {
        guard !value.isEmpty else { return .blank }
        guard numericHeaders.contains(header), let number = number(from: value) else { return .text(value) }
        return .number(number)
    }

    /// CSV numbers are written either POSIX (`2.07`) or with the display locale's decimal comma
    /// (`2,07`); both name the same quantity. Grouping separators are not produced by these rows.
    static func number(from value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains(",") ? trimmed.replacingOccurrences(of: ",", with: ".") : trimmed
        guard let number = Double(candidate), number.isFinite else { return nil }
        return number
    }

    private static func summary(for table: Table, vehicle: String, scope: String,
                                generatedAt: Date) -> [[XLSXCell]] {
        var rows: [[XLSXCell]] = [
            [.text(L10n.text("Field")), .text(L10n.text("Value"))],
            [.text(L10n.text("Dataset")), .text(table.title)],
            [.text(L10n.text("Vehicle")), .text(vehicle)],
            [.text(L10n.text("Scope")), .text(scope)],
            [.text(L10n.text("Generated")), .text(Format.iso8601.string(from: generatedAt))],
            [.text(L10n.text("Rows")), .number(Double(table.rows.count))]
        ]

        if let coordinates = coordinateRowCount(table) {
            rows.append([.text(L10n.text("Rows with coordinates")), .number(Double(coordinates))])
        }

        for header in summedHeaders {
            guard let index = table.header.firstIndex(of: header) else { continue }
            let numbers = table.rows.compactMap { row -> Double? in
                guard index < row.count else { return nil }
                return number(from: row[index])
            }
            guard numbers.count == table.rows.count, !numbers.isEmpty else { continue }
            rows.append([.text(header), .number(numbers.reduce(0, +))])
        }
        return rows
    }

    /// How many rows carry a start or end position pair. This is the same evidence the GPX export
    /// uses for a track, so a trip counted here is a trip that produced one there.
    private static func coordinateRowCount(_ table: Table) -> Int? {
        func index(_ name: String) -> Int? { table.header.firstIndex(of: name) }
        guard index("Start Latitude") != nil || index("End Latitude") != nil else { return nil }
        let startLat = index("Start Latitude"), startLon = index("Start Longitude")
        let endLat = index("End Latitude"), endLon = index("End Longitude")
        return table.rows.filter { row in
            func pair(_ lat: Int?, _ lon: Int?) -> Bool {
                guard let lat, let lon, lat < row.count, lon < row.count,
                      let latitude = number(from: row[lat]), let longitude = number(from: row[lon]) else { return false }
                return (-90...90).contains(latitude) && (-180...180).contains(longitude)
            }
            return pair(startLat, startLon) || pair(endLat, endLon)
        }.count
    }

    /// RFC 4180 with CRLF tolerated. Quoted cells may contain commas, quotes and newlines.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                case "\r": break
                default: field.append(character)
                }
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        while let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
        return rows
    }
}
