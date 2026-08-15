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

    static func distance(km: Int, grouped: Bool = false, unit: DistanceUnit) -> String {
        let value = unit.convert(km: km)
        if grouped {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return "\(formatter.string(from: NSNumber(value: value)) ?? String(value)) \(unit.suffix)"
        }
        return "\(value) \(unit.suffix)"
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

    static func completionTime(from minutes: Int, baseDate: Date = Date(), timeZone: TimeZone = .current) -> String {
        let target = baseDate.addingTimeInterval(TimeInterval(minutes * 60))
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = timeZone
        return formatter.string(from: target)
    }

    static func chargingRateKmPerHour(powerWatts: Int, consumptionWhPerKm: Double = 180.0) -> Int {
        guard powerWatts > 0, consumptionWhPerKm > 0 else { return 0 }
        let rate = Double(powerWatts) / consumptionWhPerKm
        return max(1, Int(rate.rounded()))
    }

    static func chargingRateFormatted(
        powerWatts: Int,
        consumptionWhPerKm: Double = 180.0,
        unit: DistanceUnit = .kilometers
    ) -> String {
        let kmH = chargingRateKmPerHour(powerWatts: powerWatts, consumptionWhPerKm: consumptionWhPerKm)
        let converted = unit == .kilometers ? kmH : Int((Double(kmH) * 0.621371).rounded())
        let speedSuffix = unit == .kilometers ? "km/h" : "mph"
        return "+\(converted) \(speedSuffix)"
    }

    static func fuelVolume(liters: Double, unit: FuelVolumeUnit) -> String {
        let converted = unit.convert(liters: liters)
        return String(format: "%.1f %@", converted, unit.suffix)
    }

    static func fuelEconomy(lPer100Km: Double, unit: FuelEconomyUnit) -> String {
        unit.format(lPer100Km: lPer100Km)
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

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

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
                return "\(unit.convert(km: km)) \(unit.suffix)"
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
            if includeChargingContext, data.isCharging,
               let minutes = data.estimatedChargingTimeToFullMinutes, minutes > 0 {
                return [primaryPct, Format.shortDuration(minutes: minutes)].compactMap { $0 }.joined(separator: " · ")
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
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}


