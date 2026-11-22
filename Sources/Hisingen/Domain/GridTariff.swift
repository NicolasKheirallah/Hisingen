import Foundation

/// What the grid company charges per kWh on top of the electricity price, which Tibber's price leaves out.
///
/// A flat tariff charges one rate. A time-of-use tariff (Vattenfall's "tidstariff") charges a higher
/// rate in a high-load window and a lower one the rest of the time, so the fee depends on the clock and
/// every calculation asks for it by moment or by span instead of reading one number.
///
/// Rates are öre per kWh as written on the grid invoice, VAT included, like Tibber's price. The fixed
/// yearly fee is kept for display only: it does not depend on how much is used, so it is in no per-kWh figure.
struct GridTariff: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case none
        case flat
        case vattenfallSingle
        case vattenfallTime
        /// Elvia's day/night tariff, the one Norwegian preset this model can express.
        case elviaNorway
        case custom
    }

    /// The market the tariff belongs to. It decides the currency, the unit the rate is written in,
    /// and which calendar the high-load window is read against. Defaults to Sweden, which is the
    /// only market this build ships published rates for.
    var region: GridTariffRegion = .sweden
    var kind: Kind
    /// Rate in the high-load window. Equal to `offPeakOrePerKwh` for a flat tariff.
    var peakOrePerKwh: Double
    var offPeakOrePerKwh: Double
    /// Months (1 to 12) in which the high-load window applies.
    var peakMonths: Set<Int>
    var peakStartHour: Int
    /// Exclusive, 1 to 24.
    var peakEndHour: Int
    /// High-load only on weekdays, and not on the public holidays the grid companies name.
    var peakWeekdaysOnly: Bool
    var fuseAmps: Int?
    var fixedKrPerYear: Double?
    /// The year a preset's prices are from, so the app can say when they are likely out of date.
    var priceYear: Int?

    enum CodingKeys: String, CodingKey {
        case region, kind, peakOrePerKwh, offPeakOrePerKwh, peakMonths
        case peakStartHour, peakEndHour, peakWeekdaysOnly, fuseAmps, fixedKrPerYear, priceYear
    }

    static let winterMonths: Set<Int> = [1, 2, 3, 11, 12]
    static let vattenfallPriceYear = 2026
    /// The fuse sizes Vattenfall publishes a fixed fee for, read off the fee table below so the
    /// picker and the prices can never disagree.
    static var vattenfallFuseSizes: [Int] { vattenfallFixedFee2026.keys.sorted() }
    /// Vattenfall Eldistribution, private fuse subscriptions, from 2026-01-01, VAT included.
    private static let vattenfallFixedFee2026: [Int: Double] = [
        16: 5_775, 20: 8_085, 25: 10_125, 35: 13_890, 50: 19_945, 63: 26_875
    ]

    static let none = GridTariff(kind: .none, peakOrePerKwh: 0, offPeakOrePerKwh: 0, peakMonths: [],
                                 peakStartHour: 6, peakEndHour: 22, peakWeekdaysOnly: true)

    static func flat(orePerKwh: Double) -> GridTariff {
        let rate = max(0, orePerKwh.isFinite ? orePerKwh : 0)
        return GridTariff(kind: rate > 0 ? .flat : .none, peakOrePerKwh: rate, offPeakOrePerKwh: rate, peakMonths: [],
                          peakStartHour: 6, peakEndHour: 22, peakWeekdaysOnly: true)
    }

    /// Vattenfall Eldistribution's 2026 private tariffs. E4 is the single tariff and T4 the time tariff.
    static func vattenfall(_ kind: Kind, fuseAmps: Int = 25) -> GridTariff {
        let fixed = vattenfallFixedFee2026[fuseAmps] ?? vattenfallFixedFee2026[25]
        switch kind {
        case .vattenfallTime:
            return GridTariff(kind: .vattenfallTime, peakOrePerKwh: 76.5, offPeakOrePerKwh: 30.5, peakMonths: winterMonths,
                              peakStartHour: 6, peakEndHour: 22, peakWeekdaysOnly: true, fuseAmps: fuseAmps,
                              fixedKrPerYear: fixed, priceYear: vattenfallPriceYear)
        default:
            return GridTariff(kind: .vattenfallSingle, peakOrePerKwh: 44.5, offPeakOrePerKwh: 44.5, peakMonths: [],
                              peakStartHour: 6, peakEndHour: 22, peakWeekdaysOnly: true, fuseAmps: fuseAmps,
                              fixedKrPerYear: fixed, priceYear: vattenfallPriceYear)
        }
    }

    static let elviaPriceYear = 2026
    /// Elvia, private customers, 2026, VAT and elavgift and Enova included, as on the invoice.
    /// Elvia's energy rate is the same in every capacity tier; only the fixed charge varies, and a
    /// fixed charge is in no per-kWh figure, so it is not carried here.
    static func elvia() -> GridTariff {
        GridTariff(region: .norway, kind: .elviaNorway, peakOrePerKwh: 46.40, offPeakOrePerKwh: 31.40,
                   peakMonths: [], peakStartHour: 6, peakEndHour: 22, peakWeekdaysOnly: true,
                   priceYear: elviaPriceYear)
    }

    /// A preset carries published rates for its market. The Vattenfall presets are Sweden's, so a
    /// tariff moved to another market is no longer a preset and is edited as a custom one.
    /// A Vattenfall preset belongs to Sweden. A tariff that carries one in a market without published
    /// rates — a restore or import from another build, say — is not a preset anywhere, and its figures
    /// are Swedish öre, so it is read as the reader's own numbers with the money cleared.
    var normalizedForMarket: GridTariff {
        guard !isPreset, kind == .vattenfallSingle || kind == .vattenfallTime || kind == .elviaNorway
        else { return self }
        var next = self
        next.kind = .custom
        next.priceYear = nil
        next.peakOrePerKwh = 0
        next.offPeakOrePerKwh = 0
        next.fixedKrPerYear = nil
        return next
    }

    /// The grid operator whose published price list a preset is, or `nil` when the figures were
    /// entered by the reader.
    var presetOperatorName: String? {
        guard isPreset else { return nil }
        switch kind {
        case .vattenfallSingle, .vattenfallTime: return "Vattenfall Eldistribution AB"
        case .elviaNorway: return "Elvia AS"
        default: return nil
        }
    }

    /// Whether the home's grid company is the operator this preset belongs to. A company nobody
    /// told us about matches, because a missing answer is not evidence of a mismatch.
    ///
    /// The brand word is compared rather than the whole name, so "Vattenfall AB" and
    /// "Vattenfall Eldistribution AB" agree while "Ellevio AB" does not.
    func belongsToGridCompany(_ company: String?) -> Bool {
        guard let name = presetOperatorName else { return true }
        guard let company, !company.isEmpty else { return true }
        let brand = name.split(separator: " ").first.map(String.init) ?? name
        return company.localizedCaseInsensitiveContains(brand)
    }

    /// The same tariff read in another market. The window, the months and the weekday rule are kept,
    /// because they are the part that costs effort to re-enter. The rates and the fixed fee are cleared,
    /// because they are written in the market's own currency and would otherwise be read as a different
    /// number. A Vattenfall preset belongs to Sweden, so elsewhere it becomes the reader's own figures.
    func moved(to region: GridTariffRegion) -> GridTariff {
        guard region != self.region else { return self }
        var next = self
        next.region = region
        next.peakOrePerKwh = 0
        next.offPeakOrePerKwh = 0
        next.fixedKrPerYear = nil
        if next.kind == .vattenfallSingle || next.kind == .vattenfallTime {
            next.kind = .custom
            next.priceYear = nil
        }
        return next
    }

    var isPreset: Bool {
        switch kind {
        case .vattenfallSingle, .vattenfallTime: return region == .sweden
        case .elviaNorway: return region == .norway
        default: return false
        }
    }

    /// A fee is set somewhere in the tariff.
    var hasFee: Bool { peakOrePerKwh > 0 || offPeakOrePerKwh > 0 }

    /// The rate really changes with the clock. A window with no months, no hours or the same rate in
    /// both is a flat tariff whatever it is called.
    var isTimeVarying: Bool {
        peakOrePerKwh != offPeakOrePerKwh && !peakMonths.isEmpty && peakStartHour < peakEndHour
    }

    // MARK: Fee at a moment

    /// The calendar the window is read against. It comes from the market, not from the Mac, so a
    /// travelling reader still gets the grid company's own clock.
    private var calendar: Calendar { region.calendar }

    func isPeak(at date: Date) -> Bool {
        guard isTimeVarying else { return false }
        let calendar = self.calendar
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        guard let month = parts.month, peakMonths.contains(month),
              let hour = parts.hour, hour >= peakStartHour, hour < peakEndHour else { return false }
        if peakWeekdaysOnly {
            guard let weekday = parts.weekday, (2...6).contains(weekday) else { return false }
            // Only Sweden's public holidays are known. Another market keeps the weekday rule alone,
            // because dropping a real high-load day costs more than keeping a holiday one.
            if region == .sweden,
               SwedishHolidays.isNamedHoliday(year: parts.year ?? 0, month: month, day: parts.day ?? 0) { return false }
        }
        return true
    }

    /// The market's currency units per kWh at one instant.
    func feePerKwh(at date: Date) -> Double {
        (isPeak(at: date) ? peakOrePerKwh : offPeakOrePerKwh) / 100
    }

    /// The market's currency units per kWh averaged over `[start, end)` by time, split at each full hour
    /// because the window's edges are whole hours. For an instant (`end <= start`) it is the fee at `start`.
    func averageFeePerKwh(from start: Date, to end: Date) -> Double {
        guard isTimeVarying else { return offPeakOrePerKwh / 100 }
        guard end > start else { return feePerKwh(at: start) }
        let calendar = self.calendar
        var weighted = 0.0
        var cursor = start
        while cursor < end {
            let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end ?? cursor.addingTimeInterval(3_600)
            let segmentEnd = min(max(hourEnd, cursor.addingTimeInterval(1)), end)
            weighted += segmentEnd.timeIntervalSince(cursor) * feePerKwh(at: cursor)
            cursor = segmentEnd
        }
        return weighted / end.timeIntervalSince(start)
    }

    /// The next instant the rate changes, within two weeks, or `nil` when it does not.
    func nextChange(after date: Date) -> Date? {
        guard isTimeVarying else { return nil }
        let calendar = self.calendar
        let current = isPeak(at: date)
        var cursor = calendar.dateInterval(of: .hour, for: date)?.end ?? date.addingTimeInterval(3_600)
        let limit = date.addingTimeInterval(14 * 86_400)
        while cursor < limit {
            if isPeak(at: cursor) != current { return cursor }
            cursor = calendar.dateInterval(of: .hour, for: cursor)?.end ?? cursor.addingTimeInterval(3_600)
        }
        return nil
    }

    /// The prices are from before the current year, so they may be out of date.
    func isStale(at date: Date = Date()) -> Bool {
        guard let priceYear else { return false }
        return calendar.component(.year, from: date) > priceYear
    }
}

/// The public holidays that Swedish grid companies leave out of high-load time when they fall on a weekday.
enum SwedishHolidays {
    static func isNamedHoliday(year: Int, month: Int, day: Int) -> Bool {
        switch (month, day) {
        case (1, 1), (1, 6), (12, 24), (12, 25), (12, 26), (12, 31): return true
        default: break
        }
        let easter = easterSunday(year: year)
        guard let sunday = easter else { return false }
        // Good Friday is two days before Easter Sunday and Easter Monday the day after.
        let calendar = ElectricityPriceService.stockholmCalendar
        for offset in [-2, 1] {
            guard let date = calendar.date(byAdding: .day, value: offset, to: sunday) else { continue }
            let parts = calendar.dateComponents([.month, .day], from: date)
            if parts.month == month, parts.day == day { return true }
        }
        return false
    }

    /// Easter Sunday in the Gregorian calendar (the anonymous Gregorian algorithm).
    static func easterSunday(year: Int) -> Date? {
        guard year > 1582 else { return nil }
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return ElectricityPriceService.stockholmCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}

/// Which of two grid tariffs costs less for the hours Tibber has readings for.
struct TariffComparison: Equatable, Sendable {
    var days: Int
    var kwh: Double
    /// The part of the energy used in the time tariff's high-load window, 0 to 1.
    var highLoadShare: Double
    var singleSek: Double
    var timeSek: Double

    var timeTariffIsCheaper: Bool { timeSek < singleSek }
    var differenceSek: Double { abs(singleSek - timeSek) }
}

enum TariffAdvisor {
    /// Transfer fees only, for exactly the hours given. A short window of one season says little about a
    /// year, so the caller shows it as what it is: a look at those days.
    static func compare(hours: [TibberConsumptionHour], single: GridTariff, time: GridTariff) -> TariffComparison? {
        let metered = hours.filter { $0.end > $0.start && $0.kwh.isFinite && $0.kwh > 0 }
        guard !metered.isEmpty else { return nil }
        let calendar = ElectricityPriceService.stockholmCalendar
        var kwh = 0.0, peakKwh = 0.0, singleSek = 0.0, timeSek = 0.0
        var days = Set<Date>()
        for hour in metered {
            kwh += hour.kwh
            singleSek += hour.kwh * single.averageFeePerKwh(from: hour.start, to: hour.end)
            timeSek += hour.kwh * time.averageFeePerKwh(from: hour.start, to: hour.end)
            if time.isPeak(at: hour.start) { peakKwh += hour.kwh }
            days.insert(calendar.startOfDay(for: hour.start))
        }
        return TariffComparison(days: days.count, kwh: kwh, highLoadShare: kwh > 0 ? peakKwh / kwh : 0,
                                singleSek: singleSek, timeSek: timeSek)
    }
}

extension GridTariff {
    /// Reads a stored tariff. The market is optional so a tariff saved before the country picker
    /// existed keeps its rates, instead of failing to decode and being dropped by the store.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        region = try container.decodeIfPresent(GridTariffRegion.self, forKey: .region) ?? .sweden
        kind = try container.decode(Kind.self, forKey: .kind)
        peakOrePerKwh = try container.decode(Double.self, forKey: .peakOrePerKwh)
        offPeakOrePerKwh = try container.decode(Double.self, forKey: .offPeakOrePerKwh)
        peakMonths = try container.decode(Set<Int>.self, forKey: .peakMonths)
        peakStartHour = try container.decode(Int.self, forKey: .peakStartHour)
        peakEndHour = try container.decode(Int.self, forKey: .peakEndHour)
        peakWeekdaysOnly = try container.decode(Bool.self, forKey: .peakWeekdaysOnly)
        fuseAmps = try container.decodeIfPresent(Int.self, forKey: .fuseAmps)
        fixedKrPerYear = try container.decodeIfPresent(Double.self, forKey: .fixedKrPerYear)
        priceYear = try container.decodeIfPresent(Int.self, forKey: .priceYear)
    }
}
