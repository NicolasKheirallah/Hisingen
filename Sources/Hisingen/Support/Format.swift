import AppKit


enum Format {
    static func shortDuration(minutes: Int) -> String {
        if minutes < 60 { return L10n.format("%dmin", minutes) }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? L10n.format("%dh", hours) : L10n.format("%dh%dm", hours, remainder)
    }

    static func kilowatts(watts: Int) -> String {
        let value = Double(watts) / 1_000
        return value >= 10 ? String(format: "%.0f kW", value) : String(format: "%.1f kW", value)
    }

    private static let groupedDistanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func distance(km: Int, grouped: Bool = false, unit: DistanceUnit) -> String {
        let value = unit.convert(km: km)
        if grouped {
            return "\(groupedDistanceFormatter.string(from: NSNumber(value: value)) ?? String(value)) \(unit.suffix)"
        }
        return "\(value) \(unit.suffix)"
    }

    static func distance(km: Double, decimals: Int = 1, unit: DistanceUnit) -> String {
        let value = unit == .kilometers ? km : km * UnitConversion.kilometersPerMile
        return String(format: "%.*f %@", decimals, value, unit.suffix)
    }

    static func temperature(celsius: Double, unit: TemperatureUnit, decimals: Int = 1) -> String {
        String(format: "%.*f %@", decimals, unit.convert(celsius: celsius), unit.suffix)
    }

    static func pressure(kilopascals: Double, unit: PressureUnit) -> String {
        let decimals = unit == .kilopascals ? 0 : 1
        return String(format: "%.*f %@", decimals, unit.convert(kilopascals: kilopascals), unit.suffix)
    }

    static func batteryColor(percentage: Double, charging: Bool) -> NSColor {
        if charging { return .systemGreen }
        if percentage <= 20 { return .systemOrange }
        return .controlAccentColor
    }

    static func icon(for data: VehicleState?, includeConnection: Bool = true) -> String {
        guard let data else { return "car" }
        if data.powertrain.isCombustionOnly {
            return "fuelpump.fill"
        }
        if data.powertrain.isHybrid {
            if includeConnection, data.isCharging { return "bolt.car.fill" }
            if data.isEngineRunning == true { return "engine.combustion.fill" }
            return "bolt.and.leaf.fill"
        }
        if includeConnection, data.isCharging { return "bolt.car.fill" }
        if includeConnection, data.isPluggedIn == true { return "bolt.car" }
        return "car"
    }

    static func batterySymbol(for percentage: Double?, isCharging: Bool) -> String {
        if isCharging { return "bolt.car.fill" }
        guard let percentage else { return "car" }
        if percentage >= 90 { return "battery.100percent" }
        if percentage >= 65 { return "battery.75percent" }
        if percentage >= 40 { return "battery.50percent" }
        if percentage >= 15 { return "battery.25percent" }
        return "battery.0percent"
    }

    /// A crisp SF Symbol for the security state. Keeping this separate from the menu-bar
    /// text lets AppKit render a real template image instead of a tiny, ambiguous emoji.
    static func lockStatusSymbol(for data: VehicleState?) -> String? {
        guard let isLocked = data?.exteriorStatus?.isLocked else { return nil }
        return isLocked ? "lock.fill" : "lock.open.fill"
    }

    /// Completion-time rendering shares one formatter per time zone instead of building a new
    /// `DateFormatter` per call — this feeds a computed property evaluated on every popover
    /// render while charging.
    private static let completionTimeLock = NSLock()
    nonisolated(unsafe) private static var completionTimeFormatters: [String: DateFormatter] = [:]

    static func completionTime(from minutes: Int, baseDate: Date = Date(), timeZone: TimeZone = .current) -> String {
        let target = baseDate.addingTimeInterval(TimeInterval(minutes * 60))
        let key = timeZone.identifier
        completionTimeLock.lock()
        if let cached = completionTimeFormatters[key] {
            completionTimeLock.unlock()
            return cached.string(from: target)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        completionTimeFormatters[key] = formatter
        completionTimeLock.unlock()
        return formatter.string(from: target)
    }

    static func chargingRateKmPerHour(powerWatts: Int, consumptionWhPerKm: Double = UnitConversion.defaultConsumptionWhPerKm) -> Int {
        guard powerWatts > 0, consumptionWhPerKm > 0 else { return 0 }
        let rate = Double(powerWatts) / consumptionWhPerKm
        return max(1, Int(rate.rounded()))
    }

    static func chargingRateFormatted(
        powerWatts: Int,
        consumptionWhPerKm: Double = UnitConversion.defaultConsumptionWhPerKm,
        unit: DistanceUnit = .kilometers
    ) -> String {
        let kmH = chargingRateKmPerHour(powerWatts: powerWatts, consumptionWhPerKm: consumptionWhPerKm)
        let converted = unit == .kilometers ? kmH : Int((Double(kmH) * UnitConversion.kilometersPerMile).rounded())
        let speedSuffix = unit == .kilometers ? "km/h" : "mph"
        return "+\(converted) \(speedSuffix)"
    }

    static func speed(kmH: Int, unit: DistanceUnit) -> String {
        let converted = unit == .kilometers ? kmH : Int((Double(kmH) * UnitConversion.kilometersPerMile).rounded())
        return "\(converted) \(unit == .kilometers ? "km/h" : "mph")"
    }

    static func fuelVolume(liters: Double, unit: FuelVolumeUnit) -> String {
        let converted = unit.convert(liters: liters)
        return String(format: "%.1f %@", converted, unit.suffix)
    }

    static func fuelEconomy(lPer100Km: Double, unit: FuelEconomyUnit) -> String {
        unit.format(lPer100Km: lPer100Km)
    }

    static func energyConsumption(kwhPer100Km: Double, unit: EnergyConsumptionUnit) -> String {
        unit.format(kwhPer100Km: kwhPer100Km)
    }

    /// Locale-aware decimal, so a comma-decimal system never renders "12,3" as "12.3" (or a
    /// grouped thousands separator lands mid-number). Shared across the History dashboard's
    /// many small numeric labels.
    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    private static let decimalFormatterLock = NSLock()

    private static func decimal(_ value: Double, decimals: Int, grouping: Bool = false) -> String {
        decimalFormatterLock.lock()
        defer { decimalFormatterLock.unlock() }
        decimalFormatter.minimumFractionDigits = decimals
        decimalFormatter.maximumFractionDigits = decimals
        decimalFormatter.usesGroupingSeparator = grouping
        return decimalFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.*f", decimals, value)
    }

    /// "12.3 kWh" with the platform's decimal separator.
    static func energyKwh(_ kwh: Double, decimals: Int = 1) -> String {
        L10n.format("%@ kWh", decimal(kwh, decimals: decimals))
    }

    /// "48.2 kW" — one decimal under 10 kW, whole numbers above, matching `kilowatts(watts:)`.
    static func powerKw(_ kw: Double) -> String {
        L10n.format("%@ kW", decimal(kw, decimals: kw >= 10 ? 0 : 1))
    }

    /// "+12%" / "−4%" — a real minus sign, locale digits, no separator drift.
    static func signedPercent(_ value: Double, decimals: Int = 0) -> String {
        signedNumber(value, decimals: decimals) + "%"
    }

    /// Plain locale-aware decimal with no unit, e.g. a rate like "2.3".
    static func number(_ value: Double, decimals: Int = 1) -> String {
        decimal(value, decimals: decimals)
    }

    /// "92.4%" — unsigned, locale decimal.
    static func percent(_ value: Double, decimals: Int = 0) -> String {
        decimal(value, decimals: decimals) + "%"
    }

    /// "16 A" — locale digits, non-breaking space before the unit.
    static func amps(_ value: Int) -> String {
        L10n.format("%@\u{00A0}A", decimal(Double(value), decimals: 0))
    }

    /// "+0.42" / "−0.42" — a signed plain number for trend slopes.
    static func signedNumber(_ value: Double, decimals: Int = 2) -> String {
        (value >= 0 ? "+" : "−") + decimal(abs(value), decimals: decimals)
    }

    /// "148.4 kg" — used for the History tab's CO₂ comparison.
    static func massKg(_ kg: Double, decimals: Int = 1) -> String {
        L10n.format("%@ kg", decimal(kg, decimals: decimals))
    }

    /// "12.34 kr" — amount then symbol, locale decimal. The symbol is passed through as-is so
    /// a session's own stored currency is honoured.
    static func currency(_ amount: Double, symbol: String, decimals: Int = 2) -> String {
        L10n.format("%@ %@", decimal(amount, decimals: decimals), symbol)
    }

    /// Grouped integer, e.g. "12,000" or "12 000" depending on locale.
    static func count(_ value: Int) -> String {
        decimal(Double(value), decimals: 0, grouping: true)
    }

    static func greeting(_ name: String) -> String {
        L10n.format("%@, %@", L10n.text("Hi"), name)
    }

    static func greeting(_ name: String, languageCode: String?) -> String {
        L10n.format("%@, %@", L10n.text("Hi", languageCode: languageCode), name)
    }

    static func relativeAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return L10n.text("just now") }
        if seconds < 3_600 { return L10n.format("%d min ago", seconds / 60) }
        if seconds < 86_400 { return L10n.format("%d hr ago", seconds / 3_600) }
        return L10n.format("%d d ago", seconds / 86_400)
    }

    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Shared ISO-8601 formatter for exports (previously constructed per session row).
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func shortDate(date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func shortTime(date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func scheduleText(_ schedule: VehicleSchedule) -> String {
        guard let hour = schedule.startHour, let minute = schedule.startMinute else { return L10n.text("Active") }
        let start = String(format: "%02d:%02d", hour, minute)
        let window: String
        if let endHour = schedule.endHour, let endMinute = schedule.endMinute {
            window = "\(start)–\(String(format: "%02d:%02d", endHour, endMinute))"
        } else { window = start }
        guard !schedule.weekdays.isEmpty else { return window }
        return "\(schedule.weekdays.map(\.shortName).joined(separator: ", ")) · \(window)"
    }

    static func barTitle(
        for data: VehicleState?,
        style: MenuBarStyle,
        unit: DistanceUnit,
        includeChargingContext: Bool = true
    ) -> String {
        guard let data else { return "--" }
        let primaryPct: String? = {
            if data.powertrain.isCombustionOnly {
                return data.fuelLevelPercent.map { String(format: "%.0f%%", $0) }
            }
            return data.batteryPercentage.map { String(format: "%.0f%%", $0) } ?? data.fuelLevelPercent.map { String(format: "%.0f%%", $0) }
        }()
        let primaryRange: String? = {
            if let km = data.totalCombinedRangeKm ?? data.rangeKm ?? data.fuelRangeKm {
                return "\(unit.convert(km: km))\(unit.suffix)"
            }
            return nil
        }()

        switch style {
        case .battery:
            return primaryPct ?? "--"

        case .batteryAndRange:
            return [primaryPct, primaryRange].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "--"

        case .range:
            return primaryRange ?? "--"

        case .chargingAware:
            if includeChargingContext, data.isCharging {
                // Prefer time-to-TARGET when a sub-100 % target is set; fall back to the
                // backend's time-to-full. Renders as "⚡72→80 · 25m" so the menu bar answers
                // "when do I unplug" rather than "when is it 100 %".
                let minutes = data.batteryDiagnostics?.timeToTargetMinutes
                    ?? data.estimatedChargingTimeToFullMinutes
                if let minutes, minutes > 0 {
                    let arrow = (data.chargeTargetPercentage.map { $0 < 100 } ?? false)
                        ? "→\(data.chargeTargetPercentage!)" : ""
                    let head = [primaryPct ?? "", arrow].filter { !$0.isEmpty }.joined(separator: "")
                    return "\(head) · \(Format.shortDuration(minutes: minutes))"
                }
            }
            return [primaryPct, primaryRange].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "--"

        case .compactCharging:
            if includeChargingContext, data.isCharging,
               let minutes = data.estimatedChargingTimeToFullMinutes, minutes > 0 {
                return "\(primaryPct ?? "--") (\(Format.shortDuration(minutes: minutes)))"
            }
            return primaryPct ?? "--"

        case .batteryAndPower:
            if includeChargingContext, data.isCharging,
               let power = data.chargingPowerWatts, power > 0 {
                return [primaryPct, Format.kilowatts(watts: power)].compactMap { $0 }.joined(separator: " · ")
            }
            return [primaryPct, primaryRange].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "--"

        case .iconOnly:
            return ""

        case .lockAndBattery:
            // StatusItemController and the settings preview render the lock as a native
            // SF Symbol. The title remains text-only so it is never mistaken for a lock
            // emoji with a nearly invisible open shackle.
            return primaryPct ?? "--"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
