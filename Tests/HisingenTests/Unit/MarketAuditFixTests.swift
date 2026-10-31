import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
struct MarketAuditFixTests {
    private let calendar = ElectricityPriceService.stockholmCalendar

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func coverageRequiresEveryIntervalOnTheRequestedDay() {
        let yesterday = date(2026, 2, 9)
        let today = date(2026, 2, 10)
        let todayOnly = [ElectricityPricePoint(startDate: today, endDate: today.addingTimeInterval(3600), sekPerKwh: 1)]
        #expect(!ElectricityPriceService.coversDay(todayOnly, day: yesterday))
        let end = calendar.date(byAdding: .day, value: 1, to: yesterday)!
        let gap = [ElectricityPricePoint(startDate: yesterday, endDate: yesterday.addingTimeInterval(3600), sekPerKwh: 1),
                   ElectricityPricePoint(startDate: yesterday.addingTimeInterval(7200), endDate: end, sekPerKwh: 1)]
        #expect(!ElectricityPriceService.coversDay(gap, day: yesterday))
        #expect(ElectricityPriceService.coversDay([ElectricityPricePoint(startDate: yesterday, endDate: end, sekPerKwh: 1)], day: yesterday))
        for day in [date(2026, 3, 29), date(2026, 10, 25)] {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            #expect(ElectricityPriceService.coversDay([ElectricityPricePoint(startDate: day, endDate: next, sekPerKwh: 1)], day: day))
        }
    }

    @Test func tomorrowUsesStockholmCalendarAcrossClockChanges() {
        for instant in [date(2026, 3, 28, 23), date(2026, 10, 25, 0)] {
            let tomorrow = ElectricityPriceService.tomorrow(after: instant)
            #expect(calendar.dateComponents([.day], from: calendar.startOfDay(for: instant), to: calendar.startOfDay(for: tomorrow)).day == 1)
        }
    }

    @Test func twoZonesKeepIndependentTimers() async {
        let timer = MarketTimer()
        let point = ElectricityPricePoint(startDate: Date(), endDate: Date().addingTimeInterval(172_800), sekPerKwh: 1)
        let service = ElectricityPriceService(database: .inMemory(), fetch: { _ in [point] }, wait: { _ in
            try await timer.wait()
        })
        var armed = timer.armed.makeAsyncIterator()
        _ = await service.refresh(zone: .se1)
        _ = await armed.next()
        _ = await service.refresh(zone: .se2)
        _ = await armed.next()
        #expect(await timer.cancelCount == 0)
    }

    @Test func dailyRefreshRetainsRecentHistoricalPrices() async {
        let db = VehicleDatabase.inMemory()
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let historical = ElectricityPricePoint(startDate: yesterday, endDate: today, sekPerKwh: 2)
        db.electricityPrices.save(zone: .se3, points: [historical], fetchedAt: Date())
        let current = ElectricityPricePoint(startDate: today, endDate: today.addingTimeInterval(3600), sekPerKwh: 1)
        let service = ElectricityPriceService(database: db, fetch: { _ in [current] })
        let points = await service.refresh(zone: .se3)
        #expect(points.contains(historical))
        #expect(db.electricityPrices.prices(zone: .se3).contains(historical))
    }

    @Test func historicalRequestFetchesMissingDay() async {
        let db = VehicleDatabase.inMemory()
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        db.electricityPrices.save(zone: .se3, points: [ElectricityPricePoint(startDate: today, endDate: today.addingTimeInterval(3600), sekPerKwh: 1)], fetchedAt: Date())
        let recorder = MarketFetchRecorder(point: ElectricityPricePoint(startDate: yesterday, endDate: today, sekPerKwh: 2))
        let service = ElectricityPriceService(database: db, fetch: { url in await recorder.fetch(url) })
        let result = await service.historicalPrices(zone: .se3, day: yesterday)
        #expect(await recorder.count == 1)
        #expect(result.contains { $0.startDate == yesterday })
        let vin = "MARKET-AUDIT-VIN"
        let ledger = db.charging
        let start = yesterday.addingTimeInterval(3600)
        for (minutes, soc, power, state) in [(0.0, 20.0, Optional(11.0), ChargingState.charging),
                                              (60.0, 30.0, Optional(11.0), .charging),
                                              (120.0, 40.0, Optional(11.0), .charging),
                                              (125.0, 40.0, nil, .idle), (130.0, 40.0, nil, .idle)] {
            ledger.ingest(ChargingSessionObservation(vin: vin, timestamp: start.addingTimeInterval(minutes * 60),
                soc: soc, chargingState: state, chargerConnection: power == nil ? .disconnected : .connected,
                powerKw: power, voltageVolts: nil, currentAmps: nil, chargingType: .ac, targetSoc: 80),
                configuration: ChargingSessionLedgerConfiguration(usableCapacityKwh: 79, tariffPricePerKwh: 0.37,
                    nightTariffEnabled: false, currencySymbol: "kr", locationName: nil), recordingEnabled: true)
        }
        #expect(ledger.backfillSpotEstimatedCosts(vin: vin, prices: result) == 1)
        #expect(ledger.recentChargingSessions(for: vin).first?.spotEstimatedCost != nil)
    }
}

private actor MarketFetchRecorder {
    let point: ElectricityPricePoint
    private(set) var count = 0
    init(point: ElectricityPricePoint) { self.point = point }
    func fetch(_ url: URL) -> [ElectricityPricePoint] { count += 1; return [point] }
}

private actor MarketTimer {
    nonisolated let armed: AsyncStream<Void>
    private let events: AsyncStream<Void>.Continuation
    private(set) var cancelCount = 0
    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        armed = stream
        events = continuation
    }
    func wait() async throws {
        events.yield(())
        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(3600))
        } onCancel: {
            Task { await self.cancelled() }
        }
    }
    private func cancelled() { cancelCount += 1 }
}
