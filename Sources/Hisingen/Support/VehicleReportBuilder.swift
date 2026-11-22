import AppKit
import CoreGraphics
import CoreText
import Foundation

/// The plain values the vehicle report is written from. The Info tab fills this from the
/// live vehicle state and preferences, so the builder never touches a store, a panel or a
/// file, and both report formats answer one input.
struct VehicleReportInput: Sendable {
    var modelName: String?
    var modelYear: String?
    var vin: String
    var registrationNo: String?
    var internalVehicleIdentifier: String?
    var powertrainName: String
    /// The charging state as the report names it, or nil when the powertrain has no
    /// electric range: a nil here omits the Charging and Charge Target rows, as before.
    var chargingStateName: String?
    var chargeTargetPercent: Int?
    /// The "Last changed" note for a charge target the car set long ago, pre-computed by
    /// the Info tab from the same helper the charging card uses. The builder only appends
    /// it, so it stays independent of the UI.
    var chargeTargetNote: String?
    var odometerKm: Int?
    var distanceUnit: DistanceUnit
    var batteryPercent: Double?
    /// `VehicleState.primaryRangeKm` is an integer kilometre count; the report formats it.
    var rangeKm: Int?
    var exteriorPaint: String?
    var upholstery: String?
    var buildWeek: String?
    var pno34: String?
    var marketDelivery: String?
    var softwareVersion: String?
    var serviceDueInDays: Int?
    var inServiceDate: Date?
    var factoryWarrantyValidUntil: Date?
    var batteryEstimate: BatteryHealthEstimate?
    var parkingAddress: String?
    var latitude: Double?
    var longitude: Double?
    var dataTimestamp: Date
    var generatedAt: Date
    /// Screenshot privacy mode. When on, the VIN is masked to its last four characters, the
    /// registration and the parking address are left out, and the report says so. This is
    /// the same gate the panel's privacy-sensitive views follow.
    var redacted: Bool
}

/// Builds the vehicle report the Info tab offers: the same plain-text report Copy and
/// Export have written, and a PDF of the same rows for the share sheet. A report is easy
/// to paste or attach into an email or forum thread, so the screenshot-privacy switch
/// gates the VIN, registration and location in both formats.
enum VehicleReportBuilder {
    // MARK: - Text report

    static func textReport(_ input: VehicleReportInput) -> String {
        var lines: [String] = []
        func row(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(key): \(value)")
        }

        lines.append(L10n.text("Vehicle Report"))
        lines.append(String(repeating: "=", count: 44))
        row(L10n.text("Generated"), Format.dateTimeFormatter.string(from: input.generatedAt))
        row(L10n.text("Data From"), Format.relativeAge(since: input.dataTimestamp))
        if input.redacted {
            row(L10n.text("Privacy"), L10n.text("VIN, plate, and location redacted"))
        }
        lines.append("")

        row(L10n.text("Model"), [input.modelName, input.modelYear].compactMap { $0 }.joined(separator: " "))
        row(L10n.text("VIN"), input.redacted ? maskedVIN(input.vin) : input.vin)
        if !input.redacted { row(L10n.text("Registration"), input.registrationNo) }
        row(L10n.text("Vehicle ID"), input.internalVehicleIdentifier)
        row(L10n.text("Architecture"), input.powertrainName)
        if let odometer = input.odometerKm {
            row(L10n.text("Odometer"), Format.distance(km: odometer, grouped: true, unit: input.distanceUnit))
        }
        if let battery = input.batteryPercent {
            row(L10n.text("Battery"), String(format: "%.0f%%", locale: L10n.displayLocale, battery))
        }
        if let range = input.rangeKm {
            row(L10n.text("Range"), Format.distance(km: range, unit: input.distanceUnit))
        }
        if let charging = input.chargingStateName {
            row(L10n.text("Charging"), charging)
            if let target = input.chargeTargetPercent {
                var value = "\(target)%"
                if let note = input.chargeTargetNote {
                    value += " · " + note
                }
                row(L10n.text("Charge Target"), value)
            }
        }
        row(L10n.text("Exterior Paint"), input.exteriorPaint)
        row(L10n.text("Interior Trim"), input.upholstery)
        row(L10n.text("Factory Build Week"), input.buildWeek)
        row(L10n.text("Factory Spec (PNO34)"), input.pno34)
        row(L10n.text("Market Delivery"), input.marketDelivery)
        row(L10n.text("Backend-Reported Software"), input.softwareVersion)
        if let days = input.serviceDueInDays {
            row(L10n.text("Service Due"), L10n.format("in %d days", days))
        }
        if let inService = input.inServiceDate {
            row(L10n.text("In-Service Date"), Format.dateFormatter.string(from: inService))
        }
        if let warranty = input.factoryWarrantyValidUntil {
            row(L10n.text("Manufacturer Warranty"), Format.dateFormatter.string(from: warranty))
        }

        if let estimate = input.batteryEstimate {
            lines.append("")
            row(L10n.text("Calculated SoH"), String(format: "%.1f%%", locale: L10n.displayLocale, estimate.stateOfHealthPercent))
            row(L10n.text("Calculation Method"), L10n.text("Full-charge range estimate"))
            row(L10n.text("Last 100% calculation"), Format.dateTimeFormatter.string(from: estimate.recordedAt))
            row(L10n.text("Calculated Degradation"), String(format: "%.1f%%", locale: L10n.displayLocale, estimate.degradationPercent))
        }

        if !input.redacted {
            if let address = input.parkingAddress {
                lines.append("")
                row(L10n.text("Parking Address"), address)
            }
            if let latitude = input.latitude, let longitude = input.longitude {
                row(L10n.text("Coordinates"), String(format: "%.5f, %.5f", locale: L10n.displayLocale, latitude, longitude))
            }
        }

        lines.append("")
        lines.append(L10n.text("Generated by Hisingen. Calculated values are estimates, not vehicle telemetry."))
        return lines.joined(separator: "\n")
    }

    /// The VIN as the report may show it: masked to its last four characters under
    /// screenshot privacy, in full otherwise.
    static func maskedVIN(_ vin: String) -> String {
        String(repeating: "•", count: max(0, vin.count - 4)) + String(vin.suffix(4))
    }

    // MARK: - PDF report

    /// A4 portrait, the shape a printer and a reader expect from a document report.
    private static let pageSize = CGSize(width: 595.28, height: 841.89)
    private static let margin: CGFloat = 48

    private static let ink = NSColor.black
    private static let muted = NSColor(calibratedWhite: 0.4, alpha: 1)
    private static let hairline = NSColor(calibratedWhite: 0.88, alpha: 1)
    /// Computed rather than stored: a stored static font is shared mutable state under
    /// Swift 6 concurrency, and one report build only needs each face once anyway.
    private static var titleFont: NSFont? { NSFont(name: "HelveticaNeue", size: 20) }
    private static var metaFont: NSFont? { NSFont(name: "HelveticaNeue", size: 9.5) }
    private static var rowFont: NSFont? { NSFont(name: "HelveticaNeue", size: 10.5) }

    static func pdfData(_ input: VehicleReportInput) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let info = [kCGPDFContextTitle as CFString: "Hisingen Vehicle Report"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info)
        else { return Data() }
        drawPDF(input, in: context)
        context.closePDF()
        return data as Data
    }

    /// `Hisingen Report <model> <yyyy-mm-dd>`. Carries no VIN: a shared file sits in the
    /// recipient's Downloads under its own name, and the reader may not have decided to
    /// hand over the VIN with it.
    static func pdfFileName(model: String?, generatedAt: Date) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelPart = trimmed.isEmpty ? "Vehicle" : trimmed
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: " ")
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: generatedAt)
        let date = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "Hisingen Report \(modelPart) \(date).pdf"
    }

    private static func drawPDF(_ input: VehicleReportInput, in context: CGContext) {
        // Page one carries the title block; the rows flow under it and spill onto
        // further full pages when the report is long.
        var location = 0
        let body = bodyAttributedString(input)
        let total = body.length
        let framesetter = CTFramesetterCreateWithAttributedString(body)

        var pageNumber = 0
        while true {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: pageSize))

            var bodyTop = margin
            if pageNumber == 0 {
                // Baselines walk downwards by each line's own advance, so descenders of
                // one line never touch the ascenders of the next.
                var y = pageSize.height - margin
                y = drawLine(titleLine(input), in: context, x: margin, y: y) - 14
                for line in metaLines(input) {
                    y = drawLine(line, in: context, x: margin, y: y) - 13
                }
                drawHairline(in: context, from: y, toX: pageSize.width - margin)
                bodyTop = y - 16
            }

            guard total > 0, location < total else { break }
            let bodyRect = CGRect(
                x: margin, y: margin,
                width: pageSize.width - margin * 2,
                height: bodyTop - margin
            )
            let path = CGPath(rect: bodyRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: location, length: 0), path, nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            // An empty advance means nothing fits (degenerate margins); stop instead of
            // looping over the same zero progress.
            guard visible.length > 0 else { break }
            CTFrameDraw(frame, context)
            drawRowHairlines(frame, in: context, body: body, left: margin, right: pageSize.width - margin)
            location += visible.length
            pageNumber += 1
            // A finished body leaves the page open for the single endPDFPage below;
            // beginning another would append a blank trailing page.
            if location < total { context.endPDFPage() } else { break }
        }
        context.endPDFPage()
    }

    // MARK: PDF text

    private static func titleLine(_ input: VehicleReportInput) -> CTLine {
        line(L10n.text("Vehicle Report"), font: titleFont, color: ink)
    }

    private static func metaLines(_ input: VehicleReportInput) -> [CTLine] {
        var lines = [
            line(L10n.format("Generated %@.", Format.dateTimeFormatter.string(from: input.generatedAt)), font: metaFont, color: muted),
            line(L10n.format("Data from %@.", Format.relativeAge(since: input.dataTimestamp)), font: metaFont, color: muted)
        ]
        if input.redacted {
            lines.append(line(L10n.text("VIN, plate, and location redacted"), font: metaFont, color: muted))
        }
        return lines
    }

    /// The report rows as one attributed string, in the same order and wording as the text
    /// report, so the two formats cannot drift apart.
    private static func bodyAttributedString(_ input: VehicleReportInput) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func row(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            text.append(NSAttributedString(string: "\(key): ", attributes: [
                .font: metaFont as Any, .foregroundColor: muted
            ]))
            text.append(NSAttributedString(string: value, attributes: [
                .font: rowFont as Any, .foregroundColor: ink
            ]))
            text.append(NSAttributedString(string: "\n", attributes: [
                .font: rowFont as Any, .foregroundColor: ink
            ]))
        }

        row(L10n.text("Model"), [input.modelName, input.modelYear].compactMap { $0 }.joined(separator: " "))
        row(L10n.text("VIN"), input.redacted ? maskedVIN(input.vin) : input.vin)
        if !input.redacted { row(L10n.text("Registration"), input.registrationNo) }
        row(L10n.text("Vehicle ID"), input.internalVehicleIdentifier)
        row(L10n.text("Architecture"), input.powertrainName)
        if let odometer = input.odometerKm {
            row(L10n.text("Odometer"), Format.distance(km: odometer, grouped: true, unit: input.distanceUnit))
        }
        if let battery = input.batteryPercent {
            row(L10n.text("Battery"), String(format: "%.0f%%", locale: L10n.displayLocale, battery))
        }
        if let range = input.rangeKm {
            row(L10n.text("Range"), Format.distance(km: range, unit: input.distanceUnit))
        }
        if let charging = input.chargingStateName {
            row(L10n.text("Charging"), charging)
            if let target = input.chargeTargetPercent {
                var value = "\(target)%"
                if let note = input.chargeTargetNote {
                    value += " · " + note
                }
                row(L10n.text("Charge Target"), value)
            }
        }
        row(L10n.text("Exterior Paint"), input.exteriorPaint)
        row(L10n.text("Interior Trim"), input.upholstery)
        row(L10n.text("Factory Build Week"), input.buildWeek)
        row(L10n.text("Factory Spec (PNO34)"), input.pno34)
        row(L10n.text("Market Delivery"), input.marketDelivery)
        row(L10n.text("Backend-Reported Software"), input.softwareVersion)
        if let days = input.serviceDueInDays {
            row(L10n.text("Service Due"), L10n.format("in %d days", days))
        }
        if let inService = input.inServiceDate {
            row(L10n.text("In-Service Date"), Format.dateFormatter.string(from: inService))
        }
        if let warranty = input.factoryWarrantyValidUntil {
            row(L10n.text("Manufacturer Warranty"), Format.dateFormatter.string(from: warranty))
        }
        if let estimate = input.batteryEstimate {
            row(L10n.text("Calculated SoH"), String(format: "%.1f%%", locale: L10n.displayLocale, estimate.stateOfHealthPercent))
            row(L10n.text("Calculation Method"), L10n.text("Full-charge range estimate"))
            row(L10n.text("Last 100% calculation"), Format.dateTimeFormatter.string(from: estimate.recordedAt))
            row(L10n.text("Calculated Degradation"), String(format: "%.1f%%", locale: L10n.displayLocale, estimate.degradationPercent))
        }
        if !input.redacted {
            if let address = input.parkingAddress {
                row(L10n.text("Parking Address"), address)
            }
            if let latitude = input.latitude, let longitude = input.longitude {
                row(L10n.text("Coordinates"), String(format: "%.5f, %.5f", locale: L10n.displayLocale, latitude, longitude))
            }
        }
        text.append(NSAttributedString(string: "\n" + L10n.text("Generated by Hisingen. Calculated values are estimates, not vehicle telemetry.") + "\n", attributes: [
            .font: metaFont as Any, .foregroundColor: muted
        ]))
        return text
    }

    private static func line(_ string: String, font: NSFont?, color: NSColor) -> CTLine {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font as Any, .foregroundColor: color
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Draws one line with its baseline at `y`, and returns the baseline the next line
    /// can use. PDF coordinates run from the bottom, so the caller walks downwards.
    private static func drawLine(_ line: CTLine, in context: CGContext, x: CGFloat, y: CGFloat) -> CGFloat {
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        return y
    }

    private static func drawHairline(in context: CGContext, from y: CGFloat, toX end: CGFloat) {
        context.setStrokeColor(hairline.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: y))
        context.addLine(to: CGPoint(x: end, y: y))
        context.strokePath()
    }

    /// A hairline under every row, the spec grammar the panel's own rows follow. Blank
    /// separator lines are left bare.
    private static func drawRowHairlines(
        _ frame: CTFrame, in context: CGContext, body: NSAttributedString, left: CGFloat, right: CGFloat
    ) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        origins.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), base)
        }
        context.setStrokeColor(hairline.cgColor)
        context.setLineWidth(0.5)
        for (index, line) in lines.enumerated() {
            let range = CTLineGetStringRange(line)
            guard range.location >= 0, range.length > 0,
                  range.location + range.length <= body.length else { continue }
            let slice = body.attributedSubstring(from: NSRange(location: range.location, length: range.length)).string
            if slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let origin = origins[index]
            context.move(to: CGPoint(x: left, y: origin.y - 4))
            context.addLine(to: CGPoint(x: right, y: origin.y - 4))
        }
        context.strokePath()
    }
}
