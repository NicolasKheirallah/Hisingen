import Foundation

/// The plain values a handover pack is written from. The Info tab fills this from the live
/// vehicle state and history reads, so the builder never touches a store, a panel or a file.
struct HandoverPackInput: Sendable {
    struct Field: Equatable, Sendable {
        let title: String
        let value: String
    }

    var modelName: String?
    var modelYear: String?
    var vin: String
    var registrationNo: String?
    var internalVehicleIdentifier: String?
    var pno34: String?
    var buildWeek: String?
    var exteriorPaint: String?
    var upholstery: String?
    var market: String?
    /// Hardware serial, not the VIN, but it identifies this car to anyone who reads it, so it
    /// follows the same gate as the VIN.
    var batterySerial: String?
    var equipment: [Field] = []
    /// Whether the VIN, registration and internal vehicle ID may leave the Mac in this pack.
    /// The builder writes these only when this is true, so the caller's privacy decision is the
    /// single gate.
    var includesIdentifiers: Bool
    var odometerKm: Int?
    var distanceUnit: DistanceUnit
    var batteryEstimate: BatteryHealthEstimate?
    var service: ServiceSnapshot
    var chargingSessions: [ChargingSession]
    var trips: [TripHistoryEntry]
    var lastReadingAt: Date?
    var generatedAt: Date
}

struct HandoverPack: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let name: String
        let contents: String
    }

    /// `Hisingen Handover <model> <yyyy-mm-dd>`. Carries no VIN, even when identifiers are included.
    let folderName: String
    let files: [File]
}

/// Builds the folder a seller or trader hands to a buyer. Hisingen cannot end ownership on the
/// car or in the manufacturer account, so the pack is a record plus a checklist of what the owner
/// still has to do in the Polestar or Volvo app and in the car.
///
/// Location history is never written: trip coordinates and charging location names are left
/// out of the CSVs, and no address or parking position appears anywhere.
enum HandoverPackBuilder {
    static let summaryFileName = "summary.html"
    static let chargingSessionsFileName = "charging-sessions.csv"
    static let tripsFileName = "trips.csv"
    static let passportFileName = "factory-passport.csv"

    static func build(_ input: HandoverPackInput) -> HandoverPack {
        var files = [
            HandoverPack.File(name: summaryFileName, contents: summaryHTML(input)),
            HandoverPack.File(name: chargingSessionsFileName, contents: chargingSessionsCSV(input)),
            HandoverPack.File(name: tripsFileName, contents: tripsCSV(input))
        ]
        if let passport = passportCSV(input) {
            files.append(HandoverPack.File(name: passportFileName, contents: passport))
        }
        return HandoverPack(
            folderName: folderName(model: input.modelName, generatedAt: input.generatedAt),
            files: files
        )
    }

    static func folderName(model: String?, generatedAt: Date) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelPart = trimmed.isEmpty ? "Vehicle" : trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: " ")
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: generatedAt)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "Hisingen Handover \(modelPart) \(date)"
    }

    // MARK: - Summary

    private static func summaryHTML(_ input: HandoverPackInput) -> String {
        let model = [input.modelName, input.modelYear].compactMap { $0 }.joined(separator: " ")
        var vehicleRows = [row(L10n.text("Model"), model.isEmpty ? nil : model)]
        if input.includesIdentifiers {
            vehicleRows.append(row(L10n.text("VIN"), input.vin))
            vehicleRows.append(row(L10n.text("Registration"), input.registrationNo))
            vehicleRows.append(row(L10n.text("Vehicle ID"), input.internalVehicleIdentifier))
        }
        vehicleRows += [
            row(L10n.text("Factory spec (PNO34)"), input.pno34),
            row(L10n.text("Factory build week"), input.buildWeek),
            row(L10n.text("Exterior paint"), input.exteriorPaint),
            row(L10n.text("Interior trim"), input.upholstery),
            row(L10n.text("Market delivery"), input.market)
        ]
        let identifierNote = input.includesIdentifiers
            ? L10n.text("This pack includes the VIN and registration. Keep the folder private.")
            : L10n.text("The VIN, registration and vehicle ID are left out of this pack.")

        let sections = [
            section(L10n.text("Vehicle"), [note(identifierNote)] + vehicleRows),
            section(L10n.text("Odometer"), [
                row(L10n.text("Odometer"), input.odometerKm.map {
                    Format.distance(km: $0, grouped: true, unit: input.distanceUnit)
                }),
                row(L10n.text("Vehicle data as of"), input.lastReadingAt.map { Format.dateTimeFormatter.string(from: $0) })
            ]),
            batterySection(input.batteryEstimate, unit: input.distanceUnit),
            serviceSection(input.service, unit: input.distanceUnit),
            chargingSection(input.chargingSessions),
            tripsSection(input.trips, unit: input.distanceUnit),
            checklistSection()
        ]

        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        return """
        <!doctype html>
        <html lang="\(escape(lang))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(L10n.text("Vehicle handover summary")))</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        <h1>\(escape(L10n.text("Vehicle handover summary")))</h1>
        <p class="meta">\(escape(L10n.format("Generated %@.", Format.dateTimeFormatter.string(from: input.generatedAt))))
        \(escape(L10n.text("Calculated values are estimates, not vehicle telemetry.")))</p>
        \(sections.joined(separator: "\n"))
        </body>
        </html>

        """
    }

    private static func batterySection(_ estimate: BatteryHealthEstimate?, unit: DistanceUnit) -> String {
        guard let estimate else {
            return section(L10n.text("Battery health"), [
                note(L10n.text("Hisingen has not calculated a state of health yet. It needs a reading at 100% charge."))
            ])
        }
        let confidence = estimate.method == BatteryHealthEstimator.fusedMethod
            ? L10n.text("Higher. Range and charging sessions gave similar results.")
            : L10n.text("Lower. Only one method was available.")
        let basis: String
        switch estimate.method {
        case BatteryHealthEstimator.fusedMethod:
            basis = L10n.text("Range at 100% charge and one charging session, averaged.")
        case BatteryHealthEstimator.sessionEnergyMethod:
            basis = L10n.text("One completed charging session.")
        default:
            basis = L10n.text("Vehicle-reported range at 100% charge, divided by the WLTP reference.")
        }
        let confidenceText = estimate.isRemembered
            ? confidence + " " + L10n.text("Saved from an earlier 100% reading.")
            : confidence
        var rows = [
            row(L10n.text("Calculated state of health"), percent(estimate.stateOfHealthPercent)),
            row(L10n.text("Calculated degradation"), percent(estimate.degradationPercent)),
            row(L10n.text("Estimated usable capacity"), kwh(estimate.estimatedUsableCapacityKwh)),
            row(L10n.text("Reference capacity used"), kwh(estimate.referenceUsableCapacityKwh)),
            row(L10n.text("Confidence"), confidenceText),
            row(L10n.text("Basis"), basis),
            row(L10n.text("Last 100% calculation"), Format.dateTimeFormatter.string(from: estimate.recordedAt))
        ]
        if let fullChargeRange = estimate.fullChargeRangeKm {
            rows.append(row(L10n.text("Range at 100% charge"), Format.distance(km: fullChargeRange, unit: unit)))
        }
        if let wltp = estimate.wltpReferenceRangeKm {
            rows.append(row(L10n.text("WLTP range used"), Format.distance(km: wltp, unit: unit)))
        }
        return section(L10n.text("Battery health (Hisingen estimate)"), [
            note(L10n.text("Calculated by Hisingen from range and charging data. It is not measured by the car's battery system, and it does not certify the battery."))
        ] + rows)
    }

    private static func serviceSection(_ service: ServiceSnapshot, unit: DistanceUnit) -> String {
        var warnings: [String] = []
        if service.serviceWarning {
            warnings.append(L10n.text("Service warning reported by the car."))
        }
        warnings.append(contentsOf: service.fluidWarnings.filter { !$0.isEmpty })
        let warningText = warnings.isEmpty
            ? L10n.text("No service or fluid warnings in the last reading.")
            : warnings.joined(separator: "; ")
        return section(L10n.text("Service"), [
            row(L10n.text("Days to service"), service.daysToService.map { L10n.format("in %d days", $0) }),
            row(L10n.text("Distance to service"), service.distanceToServiceKm.map { Format.distance(km: $0, unit: unit) }),
            row(L10n.text("Warnings"), warningText)
        ])
    }

    private static func chargingSection(_ sessions: [ChargingSession]) -> String {
        guard !sessions.isEmpty else {
            return section(L10n.text("Charging"), [
                note(L10n.text("No charging sessions recorded by Hisingen."))
            ])
        }
        let energy = sessions.reduce(0) { $0 + $1.kwhDelivered }
        let first = sessions.map(\.startDate).min() ?? Date()
        let last = sessions.map(\.endDate).max() ?? first
        return section(L10n.text("Charging"), [
            row(L10n.text("Charging sessions recorded"), "\(sessions.count)"),
            row(L10n.text("Energy delivered in these sessions"), Format.energyKwh(energy)),
            row(L10n.text("Period covered"), L10n.format(
                "%@ to %@",
                Format.dateTimeFormatter.string(from: first),
                Format.dateTimeFormatter.string(from: last)
            ))
        ])
    }

    private static func tripsSection(_ trips: [TripHistoryEntry], unit: DistanceUnit) -> String {
        guard !trips.isEmpty else {
            return section(L10n.text("Trips"), [note(L10n.text("No trips recorded by Hisingen."))])
        }
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        return section(L10n.text("Trips"), [
            row(L10n.text("Trips recorded"), "\(trips.count)"),
            row(L10n.text("Distance in these trips"), Format.distance(km: distance, decimals: 0, unit: unit))
        ])
    }

    private static func checklistSection() -> String {
        let items: [(String, String)] = [
            (
                L10n.text("Remove the car from your Polestar/Volvo app account"),
                L10n.text("In the Polestar or Volvo app.")
            ),
            (
                L10n.text("Factory reset the car's infotainment"),
                L10n.text("In the car or the manufacturer app.")
            ),
            (
                L10n.text("Remove digital keys and paired phones"),
                L10n.text("In the car or the manufacturer app.")
            ),
            (
                L10n.text("End plug and charge contracts"),
                L10n.text("In the manufacturer app or with your charging provider.")
            ),
            (
                L10n.text("Sign out of Hisingen and erase local data for this car"),
                L10n.text("In Hisingen: Settings, Privacy & Data, Erase This Vehicle’s Local Data. Do this last, after the export above.")
            )
        ]
        let list = items.map { item, place in
            "<li>\(escape(item))<span class=\"where\">\(escape(place))</span></li>"
        }.joined(separator: "\n")
        return section(L10n.text("Checklist"), [
            note(L10n.text("Hisingen cannot do these steps for you. Each one happens in the manufacturer app or in the car, except the last, which is in Hisingen.")),
            "<ol class=\"checklist\">\n\(list)\n</ol>"
        ])
    }

    private static let stylesheet = #"""
    :root { color-scheme: light; }
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #000; background: #fff; max-width: 680px; margin: 32px auto; padding: 0 16px; }
    h1 { font-size: 22px; margin: 0 0 4px; }
    h2 { font-size: 15px; margin: 28px 0 8px; padding-bottom: 4px; border-bottom: 1px solid #999; }
    p { margin: 0 0 8px; }
    .meta, .note { color: #555; }
    .row { display: grid; grid-template-columns: 200px 1fr; gap: 2px 16px; padding: 3px 0; border-bottom: 1px solid #e0e0e0; }
    .row dt { color: #555; margin: 0; }
    .row dd { margin: 0; }
    ol.checklist { list-style: none; margin: 8px 0 0; padding: 0; }
    ol.checklist li { position: relative; padding: 0 0 12px 26px; }
    ol.checklist li::before { content: "\2610"; position: absolute; left: 0; top: 0; }
    ol.checklist .where { display: block; color: #555; font-size: 13px; }
    @page { margin: 18mm; }
    @media (max-width: 480px) { .row { grid-template-columns: 1fr; } }
    @media print { body { margin: 0; max-width: none; } h2 { break-after: avoid; } .row, ol.checklist li { break-inside: avoid; } }
    """#

    // MARK: - CSV

    private static func chargingSessionsCSV(_ input: HandoverPackInput) -> String {
        var header = ["Session ID", "Started At", "Ended At", "Duration (min)", "Start SoC (%)", "End SoC (%)",
                      "Energy Added (kWh)", "Peak Power (kW)", "Estimated Cost", "Currency", "Energy Source", "Confidence"]
        if input.includesIdentifiers { header.insert("VIN", at: 0) }
        var lines = [header.joined(separator: ",")]
        for session in input.chargingSessions {
            var fields = [
                session.id.uuidString,
                Format.iso8601.string(from: session.startDate),
                Format.iso8601.string(from: session.endDate),
                "\(session.durationMinutes)",
                String(format: "%.1f", session.startBatteryPercentage),
                String(format: "%.1f", session.endBatteryPercentage),
                String(format: "%.2f", session.kwhDelivered),
                session.peakPowerWatts.map { String(format: "%.1f", Double($0) / 1000) } ?? "",
                session.cost.map { String(format: "%.2f", $0) } ?? "",
                session.currencySymbol ?? "",
                session.energySource.rawValue,
                session.confidence.rawValue
            ]
            if input.includesIdentifiers { fields.insert(session.vin, at: 0) }
            lines.append(fields.map { CSV.field($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Trip coordinates are deliberately absent. They are location history, and a buyer does
    /// not need them to judge the car.
    private static func tripsCSV(_ input: HandoverPackInput) -> String {
        var header = ["Trip ID", "Started At", "Ended At", "Duration (min)", "Distance (km)",
                      "Average Consumption", "Ambient Temperature (C)"]
        if input.includesIdentifiers { header.insert("VIN", at: 1) }
        var lines = [header.joined(separator: ",")]
        for trip in input.trips {
            var fields = [
                trip.id,
                Format.iso8601.string(from: trip.startedAt),
                Format.iso8601.string(from: trip.endedAt),
                String(format: "%.1f", trip.duration / 60),
                String(format: "%.2f", trip.distanceKm),
                trip.averageConsumption.map { String(format: "%.2f", $0) } ?? "",
                trip.ambientTemperatureCelsius.map { String(format: "%.1f", $0) } ?? ""
            ]
            if input.includesIdentifiers { fields.insert(trip.vin, at: 1) }
            lines.append(fields.map { CSV.field($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Factory identity as the manufacturer data reported it. Nil when there is nothing to
    /// report, so the pack does not carry an empty passport.
    private static func passportCSV(_ input: HandoverPackInput) -> String? {
        let model = [input.modelName, input.modelYear].compactMap { $0 }.joined(separator: " ")
        var rows: [[String]] = []
        if input.includesIdentifiers {
            rows.append(["VIN", input.vin])
            rows.append(["Registration No", input.registrationNo ?? ""])
            rows.append(["Internal Vehicle ID", input.internalVehicleIdentifier ?? ""])
            rows.append(["Battery Pack Serial", input.batterySerial ?? ""])
        }
        rows.append(contentsOf: [
            ["Model", model],
            ["Factory Spec (PNO34)", input.pno34 ?? ""],
            ["Factory Build Week", input.buildWeek ?? ""],
            ["Market", input.market ?? ""],
            ["Exterior Paint", input.exteriorPaint ?? ""],
            ["Upholstery", input.upholstery ?? ""]
        ])
        rows.append(contentsOf: input.equipment.map { [$0.title, $0.value] })
        let hasFactoryData = rows.contains { $0.count == 2 && !$0[1].isEmpty }
        guard hasFactoryData else { return nil }
        rows.insert(["Field", "Value"], at: 0)
        rows.append(["Exported", Format.iso8601.string(from: input.generatedAt)])
        return rows.map { $0.map { CSV.field($0) }.joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    // MARK: - HTML helpers

    private static func section(_ title: String, _ body: [String]) -> String {
        "<section>\n<h2>\(escape(title))</h2>\n\(body.joined(separator: "\n"))\n</section>"
    }

    private static func note(_ text: String) -> String {
        "<p class=\"note\">\(escape(text))</p>"
    }

    /// A labelled value. An absent value reads as "Not reported", never as zero or as a clear result.
    private static func row(_ label: String, _ value: String?) -> String {
        let shown = value.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Not reported")
        return "<div class=\"row\"><dt>\(escape(label))</dt><dd>\(escape(shown))</dd></div>"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", locale: L10n.displayLocale, value)
    }

    private static func kwh(_ value: Double) -> String {
        String(format: "%.1f kWh", locale: L10n.displayLocale, value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
