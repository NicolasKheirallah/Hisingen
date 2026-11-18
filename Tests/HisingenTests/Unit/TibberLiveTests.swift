import Foundation
import Testing
@testable import Hisingen

/// Reads the real Tibber API through `TibberClient`, so a schema change on Tibber's side fails here
/// and not in front of a reader. The mock in `TibberDirectTests` can only agree with what we think
/// the API says; this is the check that it does.
///
/// Off by default, because it needs a personal token and the network and Tibber rate-limits. Run it with
/// `HISINGEN_LIVE_TIBBER=1`; the token comes from `HISINGEN_TIBBER_TOKEN`, or from `TIBBER_ACCESS_TOKEN` in
/// the git-ignored `.env.secrets` at the repository root. Nothing it reads is printed.
@Suite("Tibber live API", .serialized)
struct TibberLiveTests {
    private static var token: String? {
        guard ProcessInfo.processInfo.environment["HISINGEN_LIVE_TIBBER"] == "1" else { return nil }
        if let value = ProcessInfo.processInfo.environment["HISINGEN_TIBBER_TOKEN"], !value.isEmpty { return value }
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let file = directory.appendingPathComponent(".env.secrets")
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                for line in text.split(separator: "\n") where line.hasPrefix("TIBBER_ACCESS_TOKEN=") {
                    let value = line.dropFirst("TIBBER_ACCESS_TOKEN=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
                    if !value.isEmpty { return value }
                }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static var enabled: Bool { token != nil }

    private func client() throws -> TibberClient {
        TibberClient(token: try #require(Self.token), transport: URLSessionHomeAssistantTransport())
    }

    @Test(.enabled(if: TibberLiveTests.enabled))
    func homesCarryTheMeteringPoint() async throws {
        let homes = try await client().homes()
        let home = try #require(homes.first)
        #expect(!home.id.isEmpty)
        #expect(home.currency != nil)
        // The price area is what the zone suggestion reads; SE1 to SE4 for a Swedish home.
        if let area = home.priceArea { #expect(home.elspotZone != nil, "unrecognised price area \(area)") }
    }

    @Test(.enabled(if: TibberLiveTests.enabled))
    func quarterHourPricesPageAndCarryLevels() async throws {
        let client = try client()
        let home = try #require(try await client.homes().first)
        let to = Date().addingTimeInterval(86_400)
        let from = Date().addingTimeInterval(-3 * 86_400)
        let points = try await client.prices(homeID: home.id, from: from, to: to)
        // Three days back is more than one page (384 slots), so this exercises the live cursors.
        #expect(points.count > 200, "expected several days of quarter-hours, got \(points.count)")
        #expect(points.allSatisfy { $0.pricePerKwh.isFinite && $0.end > $0.start })
        let slot = points.map { $0.end.timeIntervalSince($0.start) }.sorted()[points.count / 2]
        #expect(slot == 900, "slots are not quarter-hours")
        #expect(points.contains { $0.level != nil }, "no slot carried a level")
    }

    @Test(.enabled(if: TibberLiveTests.enabled))
    func hourlyConsumptionComesBackWithCost() async throws {
        let client = try client()
        let home = try #require(try await client.homes().first)
        let hours = try await client.consumption(homeID: home.id, from: Date().addingTimeInterval(-5 * 86_400), to: Date())
        #expect(hours.count > 24, "expected days of hourly readings, got \(hours.count)")
        #expect(hours.allSatisfy { $0.end.timeIntervalSince($0.start) == 3_600 && $0.kwh >= 0 })
        #expect(hours.contains { $0.cost != nil && $0.currency != nil })
    }

    /// The planner's own path: the provider the app uses, fed by the real client, resolved for today.
    /// This is what decides between "Tibber" and "Elpriser, Tibber unavailable" on the Plan tab.
    @Test(.enabled(if: TibberLiveTests.enabled))
    func plannerResolvesFromLiveTibber() async throws {
        let client = try client()
        let home = try #require(try await client.homes().first)
        let provider = PlannerPriceProvider(spot: LiveSpotStub())
        provider.setTibberSource {
            PlannerPriceProvider.TibberSource(homeID: home.id, fetch: { from, to in
                try await client.prices(homeID: home.id, from: from, to: to)
            })
        }
        let answer = await provider.resolve(zone: .se3)
        #expect(answer.origin == .tibber, "fell back to market prices: \(answer.tibberProblem ?? "no reason given")")
        #expect(answer.tibberProblem == nil)
        #expect(answer.points.count > 90, "got \(answer.points.count) slots")
        // The planner plans ahead: the series has to reach past now, not stop at it.
        #expect((answer.points.map(\.endDate).max() ?? .distantPast) >= Date().addingTimeInterval(3_600),
                "the series stops at now, so there is nothing to plan over")
        #expect(answer.level(at: Date()) != nil, "no level for the current slot")
    }
}

/// Stands in for Elpriser, so a fallback in the live test is visible as a fallback.
private struct LiveSpotStub: ChargingPlannerPriceSource {
    func prices(for zone: ElspotZone) async -> [ElectricityPricePoint] { [] }
    func fetchedAt(for zone: ElspotZone) async -> Date? { nil }
}
