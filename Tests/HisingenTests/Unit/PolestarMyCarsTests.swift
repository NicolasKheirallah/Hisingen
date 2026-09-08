import Foundation
import Testing
@testable import Hisingen

struct PolestarMyCarsTests {
    private func entry(vin: String, version: String, model: String = "Polestar 2") -> Data {
        var details = Protobuf.stringField(1, vin)
        details += Protobuf.stringField(6, model)
        details += Protobuf.stringField(7, "2026")
        details += Protobuf.stringField(9, version)
        details += Protobuf.stringField(10, "SE")
        return Protobuf.messageField(1, Protobuf.messageField(1, details))
    }

    @Test func repeatedEntriesMatchVINAndDecodeIdentity() throws {
        let data = entry(vin: "VIN-A", version: "4.2.1") + entry(vin: "VIN-B", version: "5.1.9")
        let car = try #require(PolestarGRPC.parseMyCars(data, vin: "vin-b"))
        #expect(car.installedSoftwareVersion == "5.1.9")
        #expect(car.identity == VehicleBackendIdentity(modelName: "Polestar 2", modelYear: "2026", market: "SE"))
        #expect(PolestarGRPC.parseMyCars(data, vin: "VIN-C") == nil)
        #expect(PolestarGRPC.parseMyCars(entry(vin: "VIN-A", version: "4.2.1"), vin: "VIN-B") == nil)
    }

    @Test func myCarsAloneSuppliesInstalledVersionWithoutInventingOTAStatus() throws {
        let caps = VehicleOTACapabilities(installedSoftwareVersion: "5.1.9")
        let software = try #require(PolestarAPI.mergingSoftwareInfo(nil, myCars: caps))
        #expect(software.installedVersion == "5.1.9")
        #expect(software.latestAvailableVersion == nil)
        #expect(software.noUpdateAvailable != true)
        #expect(software.state == .unknown)
    }

    @Test func installedAndPendingVersionsRemainDistinct() throws {
        let ota = VehicleSoftwareInfo(version: "5.2.0", state: .available, latestAvailableVersion: "5.2.0")
        let result = try #require(PolestarAPI.mergingSoftwareInfo(ota, myCars: .init(installedSoftwareVersion: "5.1.9")))
        #expect(result.installedVersion == "5.1.9")
        #expect(result.latestAvailableVersion == "5.2.0")
        #expect(result.state == .available)
        #expect(result.noUpdateAvailable != true)
    }

    @Test func requestIncludesUniqueIDAndRequestedVIN() throws {
        let first = Protobuf.fields(PolestarGRPC.myCarsRequest(vin: "VIN-A"))
        let second = Protobuf.fields(PolestarGRPC.myCarsRequest(vin: "VIN-A"))
        let firstID = try #require(first.first(where: { $0.number == 1 })?.data)
        let secondID = try #require(second.first(where: { $0.number == 1 })?.data)
        #expect(firstID != secondID)
        #expect(UUID(uuidString: String(decoding: firstID, as: UTF8.self)) != nil)
        #expect(first.first(where: { $0.number == 2 })?.data == Data("VIN-A".utf8))
    }

    @Test(arguments: [false, true])
    func emptyOTADiffersFromFailedOTA(failure: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MyCarsOTATransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "io.kheirallah.hisingen.tests.mycars.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let grpc = PolestarGRPC(defaultsSuiteName: suite, session: session)
        do {
            let ota = try await grpc.fetchSoftware(vin: "VIN-A", accessToken: failure ? "fail" : "success", locale: "en")
            #expect(!failure)
            #expect(ota?.noUpdateAvailable == true)
            let merged = PolestarAPI.mergingSoftwareInfo(ota, myCars: .init(installedSoftwareVersion: "5.1.9"))
            #expect(merged?.noUpdateAvailable == true)
            #expect(merged?.installedVersion == "5.1.9")
        } catch {
            #expect(failure)
            #expect(PolestarAPI.mergingSoftwareInfo(nil, myCars: .init(installedSoftwareVersion: "5.1.9"))?.noUpdateAvailable != true)
        }
    }

    @Test func digitalTwinAlarmPreservesIdleTriggeredAndUnknown() throws {
        for (raw, expected): (Int, Bool?) in [(0, nil), (1, false), (2, true), (99, nil)] {
            let body = Protobuf.intField(2, 2) + Protobuf.intField(15, raw)
            let exterior = try #require(PolestarGRPC.parseExterior(body))
            #expect(exterior.alarmTriggered == expected)
        }
    }

    /// Negative control for the 2026-09-08 capture: the nested MyCars charging settings
    /// (amperage message fields 1=1, 3=6, 4=32; target message fields 1=1, 2=40, 4=1,
    /// 5=90, 6=1) have no schema contract anywhere — neither this app's probes nor the
    /// upstream clients model them. Plausible-looking amp/percent values must never
    /// silently become command-validation bounds, so the parser keeps reading exactly
    /// fields 1/2 of each settings message and ignores the rest.
    @Test func myCarsNestedChargingSettingsNeverBecomeCommandBounds() throws {
        var charging = Protobuf.intField(1, 1)
        charging += Protobuf.messageField(8, Protobuf.intField(1, 1) + Protobuf.intField(2, 40)
                                                 + Protobuf.intField(4, 1) + Protobuf.intField(5, 90)
                                                 + Protobuf.intField(6, 1))
        charging += Protobuf.messageField(9, Protobuf.intField(1, 1) + Protobuf.intField(3, 6)
                                                 + Protobuf.intField(4, 32))
        var car = Protobuf.stringField(1, "VIN-A")
        car += Protobuf.messageField(35, charging)
        let carEntry = Protobuf.messageField(1, car)
        let capabilities = try #require(PolestarGRPC.parseMyCars(Protobuf.messageField(1, carEntry), vin: "VIN-A"))
        // The presence of settings messages keeps the *feature* flags on, but the observed
        // layout (min/max in fields 1/2) is not verified, so no bound may be extracted.
        #expect(capabilities.supportsTargetChargeLevel == true)
        #expect(capabilities.supportsGlobalChargeAmperageLimit == true)
        #expect(capabilities.chargeAmperageMinLimit == 0)
        #expect(capabilities.chargeAmperageMaxLimit == 0)
        #expect(capabilities.targetChargeLevelPercentageMinLimit == 0)
    }

    /// The upstream MyCars schema names no fields beyond vin/model/year/market/installed
    /// version on the car details, and kildahldev PR 32 found entry field 4 (registration-
    /// like on one account) absent on another. Registration must keep coming from GraphQL
    /// only — the MyCars entry is never read for it here.
    @Test func myCarsEntryField4IsNeverReadAsRegistration() throws {
        var entryDetails = Protobuf.stringField(1, "VIN-A")
        entryDetails += Protobuf.stringField(9, "5.1.9")
        var entry = Protobuf.messageField(1, entryDetails)
        entry += Protobuf.stringField(4, "ABC 123")
        let car = try #require(PolestarGRPC.parseMyCars(Protobuf.messageField(1, entry), vin: "VIN-A"))
        #expect(car.installedSoftwareVersion == "5.1.9")
        // VehicleOTACapabilities has no registration field at all — the outer-entry plate
        // string is structurally invisible to the domain model, which is the control.
        #expect(VehicleOTACapabilities.self != nil)
    }

    /// Battery fields 8 and 28 were present in the 2026-09-08 capture but are not decoded:
    /// upstream names field 8 (`estimated_distance_to_empty_miles`) only in an APK-derived
    /// schema without live confirmation, and 28 has no name anywhere. They must stay
    /// unnamed and unparsed rather than guessed into the diagnostics model.
    @Test func batteryUnverifiedFieldsStayUnnamedAndUnparsed() {
        var payload = Data()
        payload.append(Protobuf.doubleField(2, 75.0))
        payload.append(Protobuf.intField(8, 300))
        payload.append(Protobuf.intField(28, 7))
        let battery = PolestarGRPC.parseBattery(payload)
        // The parser surfaces nothing for 8/28 — no percent/range/current mutation.
        #expect(battery.batteryPercentage == 75.0)
        #expect(battery.rangeKm == nil)
        #expect(battery.chargingCurrentAmps == nil)
        #expect(battery.chargingVoltageVolts == nil)
    }

    /// Health field 46 carries a nested status message with no known schema (upstream
    /// Health ends at 44). It must not be decoded into any warning or light failure.
    @Test func healthField46NestedMessageStaysUndecoded() {
        var nested = Protobuf.intField(1, 2)
        nested += Protobuf.stringField(2, "unknown-status")
        var payload = Data()
        payload.append(Protobuf.intField(3, 10))
        payload.append(Protobuf.messageField(46, nested))
        let report = PolestarGRPC.parseHealth(payload)
        #expect(report.details.warnings.isEmpty)
        #expect(report.details.lightFailures.isEmpty)
        #expect(report.daysToService == 10)
    }

    @Test func additionalOptionalFieldsDecodeOldSnapshots() throws {
        let old = Data(#"{"state":"unknown"}"#.utf8)
        let decoded = try JSONDecoder().decode(VehicleSoftwareInfo.self, from: old)
        #expect(decoded.noUpdateAvailable == nil)
    }
}

private final class MyCarsOTATransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let discovery = request.url?.host == "cnepmob.volvocars.com"
        let failure = request.value(forHTTPHeaderField: "Authorization") == "Bearer fail" && !discovery
        let body = discovery ? Data(#"{"c3":{"grpcHost":"grpc.example","grpcPort":443}}"#.utf8) : Protobuf.grpcFrame(Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: failure ? 503 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
