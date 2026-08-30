import Foundation

enum SwedishPriceArea: String, CaseIterable, Codable, Identifiable, Sendable {
    case se1 = "SE1"
    case se2 = "SE2"
    case se3 = "SE3"
    case se4 = "SE4"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .se1: return "SE1 · Luleå"
        case .se2: return "SE2 · Sundsvall"
        case .se3: return "SE3 · Stockholm / Göteborg"
        case .se4: return "SE4 · Malmö"
        }
    }
}

struct SpotPriceInterval: Codable, Equatable, Sendable {
    let sekPerKWh: Double
    let eurPerKWh: Double?
    let exchangeRate: Double?
    let start: Date
    let end: Date

    enum CodingKeys: String, CodingKey {
        case sekPerKWh = "SEK_per_kWh"
        case eurPerKWh = "EUR_per_kWh"
        case exchangeRate = "EXR"
        case start = "time_start"
        case end = "time_end"
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct SmartChargingRecommendation: Equatable, Sendable {
    let start: Date
    let end: Date
    let energyKWh: Double
    let averageSEKPerKWh: Double
    let estimatedCostSEK: Double
    let intervalCount: Int

    var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Finds the least-cost contiguous window at source interval boundaries. The final
    /// interval may be used partially. This supports both historical hourly rows and the
    /// 15-minute rows Sweden has published since October 2025.
    static func cheapestWindow(
        prices: [SpotPriceInterval],
        energyKWh: Double,
        chargingPowerKW: Double,
        notBefore: Date
    ) -> SmartChargingRecommendation? {
        guard energyKWh > 0, chargingPowerKW > 0 else { return nil }
        let usable = prices
            .filter { $0.end > notBefore && $0.end > $0.start && $0.sekPerKWh.isFinite }
            .sorted { $0.start < $1.start }
        guard !usable.isEmpty else { return nil }

        var best: SmartChargingRecommendation?
        for startIndex in usable.indices {
            var remaining = energyKWh
            var cost = 0.0
            var usedIntervals = 0
            let candidateStart = max(usable[startIndex].start, notBefore)
            var cursor = candidateStart

            for index in startIndex..<usable.count {
                let interval = usable[index]
                let segmentStart = max(interval.start, cursor)
                guard segmentStart < interval.end else { continue }
                // A gap breaks contiguity. One second tolerates timestamp rounding only.
                if segmentStart.timeIntervalSince(cursor) > 1 { break }
                let availableHours = interval.end.timeIntervalSince(segmentStart) / 3_600
                let availableEnergy = chargingPowerKW * availableHours
                let usedEnergy = min(remaining, availableEnergy)
                let usedHours = usedEnergy / chargingPowerKW
                cost += usedEnergy * interval.sekPerKWh
                remaining -= usedEnergy
                usedIntervals += 1
                cursor = segmentStart.addingTimeInterval(usedHours * 3_600)

                if remaining <= 0.000_001 {
                    let candidate = SmartChargingRecommendation(
                        start: candidateStart,
                        end: cursor,
                        energyKWh: energyKWh,
                        averageSEKPerKWh: cost / energyKWh,
                        estimatedCostSEK: cost,
                        intervalCount: usedIntervals
                    )
                    if best == nil
                        || candidate.estimatedCostSEK < best!.estimatedCostSEK - 0.000_001
                        || (abs(candidate.estimatedCostSEK - best!.estimatedCostSEK) < 0.000_001
                            && candidate.start < best!.start) {
                        best = candidate
                    }
                    break
                }
                cursor = interval.end
            }
        }
        return best
    }
}

enum SpotPriceServiceError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L10n.text("Could not build the electricity-price URL.")
        case .httpStatus(404): return L10n.text("Prices for that day have not been published yet.")
        case .httpStatus(let status): return L10n.format("The price service returned HTTP %d.", status)
        case .invalidResponse: return L10n.text("The price service returned invalid data.")
        }
    }
}

/// Fetches Swedish day-ahead electricity prices from elprisetjustnu.se — a free, key-less,
/// public feed. These calls deliberately use a plain `URLSession` rather than the provider
/// `perform()` path: the data carries no credentials or PII, and it should not appear in the
/// vehicle-API diagnostic log. elprisetjustnu.se asks non-commercial callers to send an
/// identifying `User-Agent`, so this does.
struct SpotPriceService: Sendable {
    let session: URLSession

    private static let userAgent = "Hisingen/1.x (+https://nicolaskheirallah.github.io/Hisingen/)"

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func endpoint(date: Date, area: SwedishPriceArea,
                         calendar: Calendar = .current) -> URL? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        return URL(string: String(
            format: "https://www.elprisetjustnu.se/api/v1/prices/%04d/%02d-%02d_%@.json",
            year, month, day, area.rawValue
        ))
    }

    static func decode(_ data: Data) throws -> [SpotPriceInterval] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SpotPriceInterval].self, from: data)
            .filter { $0.end > $0.start && $0.sekPerKWh.isFinite }
    }

    func fetch(date: Date, area: SwedishPriceArea) async throws -> [SpotPriceInterval] {
        guard let url = Self.endpoint(date: date, area: area) else {
            throw SpotPriceServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SpotPriceServiceError.invalidResponse
        }
        guard http.statusCode == 200 else { throw SpotPriceServiceError.httpStatus(http.statusCode) }
        return try Self.decode(data)
    }

    func fetchTodayAndTomorrow(area: SwedishPriceArea, now: Date = Date(),
                               calendar: Calendar = .current) async throws -> [SpotPriceInterval] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        async let todayTask = fetch(date: now, area: area)
        async let tomorrowTask: [SpotPriceInterval]? = try? fetch(date: tomorrow, area: area)
        let today = try await todayTask
        return (today + (await tomorrowTask ?? [])).sorted { $0.start < $1.start }
    }
}
