import Foundation
import Testing
@testable import Hisingen

/// Opt-in, read-only probe of the real Perific cloud with the reader's own account. It needs
/// `HISINGEN_ENABLE_PERIFIC_PROBES=1`, `PERIFIC_USERNAME` and `PERIFIC_PASSWORD` in the process
/// environment (see `.env.example`), and sends only a login and reads. Off by default, so CI never
/// contacts Perific:
///
///     set -a; . ./.env.secrets; set +a
///     HISINGEN_ENABLE_PERIFIC_PROBES=1 sh Scripts/test.sh --filter LivePerificProbeTests
@Suite("Live Perific probe", .serialized)
struct LivePerificProbeTests {
    private static let env = ProcessInfo.processInfo.environment
    private static let enabled = env["HISINGEN_ENABLE_PERIFIC_PROBES"] == "1"
        && !(env["PERIFIC_USERNAME"] ?? "").isEmpty && !(env["PERIFIC_PASSWORD"] ?? "").isEmpty

    @Test("The client signs in, finds the meter, reads it and reads its history", .enabled(if: LivePerificProbeTests.enabled))
    func readsTheRealMeter() async throws {
        let credentials = DirectChargerCredentials(username: Self.env["PERIFIC_USERNAME"] ?? "",
                                                   password: Self.env["PERIFIC_PASSWORD"] ?? "")
        let client = PerificClient(credentials: credentials, transport: URLSessionHomeAssistantTransport())

        let meters = try await client.meters()
        let meter = try #require(meters.first, "no meter on the account")
        print("PROBE meters:", meters.count, "zone:", meter.timeZoneIdentifier ?? "nil")

        let reading = try #require(try await client.latest(meterID: meter.id), "the account does not list the meter")
        let age = reading.age(now: Date())
        print("PROBE reading: phases", reading.phases.map { "\($0.amps) A \($0.volts) V" },
              "net W", Int(reading.netWatts), "age s", Int(age),
              "hwi", reading.importedKwh ?? -1, "hwo", reading.exportedKwh ?? -1, "assumed V", reading.voltageAssumed)
        #expect(reading.phases.count == 3)
        #expect(reading.phases.allSatisfy { $0.volts > 180 && $0.volts < 260 })
        #expect(age < 600, "the newest packet is \(Int(age)) s old")
        #expect(reading.importedKwh != nil)

        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = meter.timeZone
        let midnight = calendar.startOfDay(for: now)
        let today = try await client.registers(meterID: meter.id, timeZone: meter.timeZone,
                                               from: midnight.addingTimeInterval(-120), to: now)
        let span = try #require(HouseMeterHistory.span(today), "no register span for today (\(today.count) points)")
        print("PROBE today points:", today.count, "imported kWh:", span.importedKwh, "exported kWh:", span.exportedKwh)
        #expect(span.importedKwh >= 0)
        // The live packets carry the day register too. It has to agree with the history within the
        // couple of minutes the history window reaches back before midnight, or the card's figure
        // is measuring from the wrong midnight.
        let fromDayPacket = try #require(HouseMeterHistory.today(reading, in: meter.timeZone),
                                         "the day packet did not read as local midnight")
        print("PROBE today from day packet:", fromDayPacket.importedKwh, "from history:", span.importedKwh)
        #expect(abs(fromDayPacket.importedKwh - span.importedKwh) < 0.5,
                "day packet and history differ by \(fromDayPacket.importedKwh - span.importedKwh) kWh")
        // The newest history point is the minute just gone, in local time converted to the right instant.
        let newest = try #require(today.last)
        #expect(abs(newest.at.timeIntervalSince(now)) < 600, "history labels are off by \(Int(newest.at.timeIntervalSince(now))) s")

        let registers = try await client.hourlyRegisters(meterID: meter.id, timeZone: meter.timeZone,
                                                         from: now.addingTimeInterval(-62 * 86_400), to: now)
        let hours = HouseMeterHistory.hourlyImport(registers)
        print("PROBE hourly points:", registers.count, "hours:", hours.count,
              "total kWh:", hours.reduce(0) { $0 + $1.kwh }, "from:", hours.first?.start as Any)
        #expect(!hours.isEmpty)
        #expect(hours.allSatisfy { $0.kwh >= 0 && $0.kwh < 30 })
    }
}
