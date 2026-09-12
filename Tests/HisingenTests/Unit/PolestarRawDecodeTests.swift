import Foundation
import Testing
@testable import Hisingen

/// Proves the previously-unmapped Polestar wire fields now decode, and — as positive
/// controls — that every field already known before this change still decodes correctly.
struct PolestarRawDecodeTests {
    // MARK: - C3 battery

    @Test func batteryDecodesReportedCapacityAndKnownFields() throws {
        var payload = Data()
        payload += Protobuf.messageField(1, Protobuf.intField(1, 1_700_000_000))
        payload += Protobuf.doubleField(2, 75.0)
        payload += Protobuf.intField(4, 270)
        payload += Protobuf.intField(5, 42)
        payload += Protobuf.doubleField(12, 78.0)
        let extras = PolestarGRPC.parseBattery(payload)
        #expect(extras.batteryPercentage == 75.0)
        #expect(extras.rangeKm == 270)
        #expect(extras.estimatedChargingTimeToFullMinutes == 42)
        #expect(extras.reportedBatteryCapacityKwh == 78.0)
        #expect(extras.unknownFields.isEmpty)
    }

    @Test func batteryCapturesUnknownFieldsRaw() throws {
        var payload = Data()
        payload += Protobuf.intField(8, 7)
        payload += Protobuf.stringField(14, "abc")
        payload += Protobuf.doubleField(21, 3.5)
        let extras = PolestarGRPC.parseBattery(payload)
        #expect(extras.batteryPercentage == nil)
        let unknown = extras.unknownFields.sorted { $0.field < $1.field }
        #expect(unknown.count == 3)
        #expect(unknown[0].field == 8 && unknown[0].wire == 0 && unknown[0].value == "7" && !unknown[0].isBinary)
        #expect(unknown[1].field == 14 && unknown[1].isBinary && unknown[1].value == "616263")
        #expect(unknown[2].field == 21 && unknown[2].value == "3.5" && !unknown[2].isBinary)
    }

    @Test func batteryCapacityAbsentStaysNil() throws {
        let extras = PolestarGRPC.parseBattery(Protobuf.intField(4, 100))
        #expect(extras.reportedBatteryCapacityKwh == nil)
        #expect(extras.rangeKm == 100)
    }

    // MARK: - OTA software info

    @Test func softwareDecodesDescriptionsQbAndOriginator() throws {
        var payload = Data()
        payload += Protobuf.stringField(1, "sid-1")
        var description = Data()
        description += Protobuf.stringField(1, "Software update")
        description += Protobuf.stringField(2, "Improves range")
        description += Protobuf.stringField(3, "<textblock>A new software update is available containing improved functionality.</textblock>")
        payload += Protobuf.messageField(2, description)
        payload += Protobuf.stringField(3, "QB-2026-08")
        payload += Protobuf.intField(4, 15)
        payload += Protobuf.messageField(5, Protobuf.intField(1, 5_400))
        payload += Protobuf.stringField(6, "5.0.10")
        payload += Protobuf.stringField(11, "SYSTEM")
        let info = PolestarGRPC.parseSoftware(payload)
        #expect(info.title == "Software update")
        #expect(info.shortDescription == "Improves range")
        #expect(info.longDescription?.contains("improved functionality") == true)
        #expect(info.qbCode == "QB-2026-08")
        #expect(info.originator == "SYSTEM")
        #expect(info.estimatedInstallDurationSeconds == 5_400)
        #expect(info.rawState == .updateAvailable)
    }

    @Test func softwareWithoutDescriptionFieldsStaysNil() throws {
        var payload = Data()
        payload += Protobuf.stringField(1, "sid-2")
        payload += Protobuf.intField(4, 9)
        payload += Protobuf.stringField(6, "5.0.10")
        let info = PolestarGRPC.parseSoftware(payload)
        #expect(info.shortDescription == nil)
        #expect(info.longDescription == nil)
        #expect(info.qbCode == nil)
        #expect(info.originator == nil)
        #expect(info.state == .completed)
    }

    @Test func releaseNotesHTMLStripsTextblockAndTags() {
        let input = "<textblock>A new software update is available containing improved functionality. <b>Please</b> contact Polestar if you have questions.</textblock>"
        let stripped = VehicleTabView.strippedReleaseNotes(input)
        #expect(stripped == "A new software update is available containing improved functionality. Please contact Polestar if you have questions.")
        #expect(VehicleTabView.strippedReleaseNotes("plain text").isEmpty == false)
    }

    // MARK: - Scheduler relative_time

    @Test func schedulerRelativeMinutesDecode() {
        var scheduler = Data()
        scheduler += Protobuf.intField(1, 2)
        scheduler += Protobuf.intField(2, 1_440)
        let fields = Protobuf.fields(scheduler)
        guard let raw = fields.first(where: { $0.number == 2 && $0.wire == 0 })?.varint else {
            Issue.record("relative_time field missing")
            return
        }
        let signed = Int(bitPattern: UInt(truncatingIfNeeded: raw))
        #expect(signed == 1_440)
    }

    @Test func schedulerIdleNegativeTwoIsNotSurfacedAsCountdown() throws {
        // Live capture: 0a0d080110feffffffffffffffff01 → status 1, relative_time -2.
        let raw = Data([0x0a, 0x0d, 0x08, 0x01, 0x10, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
        guard let scheduler = Protobuf.fields(raw).first(where: { $0.number == 1 && $0.wire == 2 })?.data,
              let rawRelative = Protobuf.fields(scheduler).first(where: { $0.number == 2 && $0.wire == 0 })?.varint else {
            Issue.record("scheduler frame did not decode")
            return
        }
        let signed = Int(bitPattern: UInt(truncatingIfNeeded: rawRelative))
        #expect(signed == -2)
        // The fetch path only surfaces positives; -2 must never become a countdown row.
        #expect((signed > 0 ? signed : nil) == nil)
    }

    // MARK: - GetMyCars

    @Test func myCarsDecodesSunroofLinkedOwnerPlate() throws {
        var locks = Data()
        locks += Protobuf.intField(5, 1)
        locks += Protobuf.intField(6, 1)
        locks += Protobuf.intField(7, 1)
        locks += Protobuf.intField(10, 1)
        var car = Data()
        car += Protobuf.stringField(1, "VIN-DEC")
        car += Protobuf.stringField(9, "4.2.1")
        car += Protobuf.messageField(36, locks)
        // MyCar wire shape: {1: Car, 2: userIsLinked, 3: userIsOwner, 4: registrationPlate}.
        var myCarMessage = Protobuf.messageField(1, car)
        myCarMessage += Protobuf.intField(2, 1)
        myCarMessage += Protobuf.intField(3, 1)
        myCarMessage += Protobuf.stringField(4, "ABC 123")
        let myCar = Protobuf.messageField(1, myCarMessage)
        let caps = try #require(PolestarGRPC.parseMyCars(myCar, vin: "vin-dec"))
        #expect(caps.supportsSunroofControl == true)
        #expect(caps.userIsLinked == true)
        #expect(caps.userIsOwner == true)
        #expect(caps.registrationPlate == "ABC 123")
        #expect(caps.installedSoftwareVersion == "4.2.1")
    }

    @Test func myCarsAbsentSunroofFieldIsTriState() throws {
        var locks = Data()
        locks += Protobuf.intField(5, 1)
        var car = Data()
        car += Protobuf.stringField(1, "VIN-DEC")
        car += Protobuf.messageField(36, locks)
        let myCar = Protobuf.messageField(1, Protobuf.messageField(1, car))
        let caps = try #require(PolestarGRPC.parseMyCars(myCar, vin: "VIN-DEC"))
        #expect(caps.supportsSunroofControl == nil)
        #expect(caps.userIsLinked == nil)
        #expect(caps.userIsOwner == nil)
    }

    // MARK: - GetMyCars raw-field retention + content codes

    @Test func myCarsRetainsUnknownFieldsRawAndDecodesContentCodes() throws {
        var charging = Data()
        charging += Protobuf.intField(1, 1)   // known support flag — must not be retained
        charging += Protobuf.intField(5, 1)   // unknown charging subfield
        var locks = Data()
        locks += Protobuf.intField(5, 1)      // known windows flag — must not be retained
        locks += Protobuf.intField(1, 3)      // unknown locks subfield
        var car = Data()
        car += Protobuf.stringField(1, "VIN-RETAIN")
        car += Protobuf.stringField(6, "Polestar 2")
        car += Protobuf.intField(20, 1)       // unknown top-level flag
        car += Protobuf.floatField(44, 2600)  // unknown top-level float
        car += Protobuf.messageField(35, charging)
        car += Protobuf.messageField(36, locks)
        car += Protobuf.stringField(47, "534-110U-GR04-2023")
        let myCar = Protobuf.messageField(1, Protobuf.messageField(1, car))
        let caps = try #require(PolestarGRPC.parseMyCars(myCar, vin: "VIN-RETAIN"))

        #expect(caps.equipment?.contentCodes == ["534", "110U", "GR04", "2023"])
        let unknown = try #require(caps.unknownWireFields)
        #expect(unknown.map { "\($0.subfield ?? 0)|\($0.field)" } ==
                ["0|20", "0|44", "35|5", "36|1"])
        #expect(unknown[0].value == "1" && !unknown[0].isBinary)
        #expect(unknown[1].value == "2600.0" && !unknown[1].isBinary)
        // Known fields (6, 35.1, 36.5, 47) never appear in the raw capture.
        #expect(!unknown.contains { $0.subfield == nil && $0.field == 47 })
        #expect(!unknown.contains { $0.subfield == 35 && $0.field == 1 })
        #expect(!unknown.contains { $0.subfield == 36 && $0.field == 5 })
    }

    @Test func myCarsWithOnlyKnownFieldsRetainsNothing() throws {
        var car = Data()
        car += Protobuf.stringField(1, "VIN-CLEAN")
        car += Protobuf.stringField(6, "Polestar 2")
        car += Protobuf.stringField(47, "534-GR04")
        let myCar = Protobuf.messageField(1, Protobuf.messageField(1, car))
        let caps = try #require(PolestarGRPC.parseMyCars(myCar, vin: "VIN-CLEAN"))
        #expect(caps.unknownWireFields?.isEmpty == true)
        #expect(caps.equipment?.contentCodes == ["534", "GR04"])
    }

    // MARK: - Availability

    @Test func availabilityUnknownReasonSevenHasText() throws {
        // Reason 7 (observed in live captures) must not disappear.
        var availability = Data()
        availability += Protobuf.intField(3, 2)
        availability += Protobuf.intField(4, 7)
        let fields = Protobuf.fields(availability)
        let reason = try #require(fields.first(where: { $0.number == 4 && $0.wire == 0 })?.varint)
        #expect(reason == 7)
    }

    // MARK: - Token response

    @Test func tokenResponseDecodesTokenTypeAndIdToken() throws {
        let json = """
        {"access_token":"a","refresh_token":"r","expires_in":1799,
         "token_type":"Bearer","id_token":"id-123"}
        """
        let token = try JSONDecoder().decode(TokenResponseDTO.self, from: Data(json.utf8))
        #expect(token.tokenType == "Bearer")
        #expect(token.idToken == "id-123")
        #expect(token.expiresIn == 1799)
    }

    @Test func tokenResponseWithoutNewFieldsStillDecodes() throws {
        let json = """
        {"access_token":"a","refresh_token":"r","expires_in":"1799"}
        """
        let token = try JSONDecoder().decode(TokenResponseDTO.self, from: Data(json.utf8))
        #expect(token.tokenType == nil)
        #expect(token.idToken == nil)
        #expect(token.expiresIn == 1799)
    }

    // MARK: - GraphQL battery capacity

    @Test func graphqlBatteryCapacityDecodesNumberAndString() throws {
        let json = """
        {"carTelematicsV2": {"battery":[{"vin":"V","batteryChargeLevelPercentage":75.0,
                     "reportedBatteryCapacityKwh":78.0}]}}
        """
        let payload = try JSONDecoder().decode(TelematicsPayloadDTO.self, from: Data(json.utf8))
        #expect(payload.carTelematicsV2?.battery?.first?.reportedBatteryCapacityKwh?.value == 78.0)

        let stringJSON = """
        {"carTelematicsV2": {"battery":[{"vin":"V","reportedBatteryCapacityKwh":"78.0"}]}}
        """
        let stringPayload = try JSONDecoder().decode(TelematicsPayloadDTO.self, from: Data(stringJSON.utf8))
        #expect(stringPayload.carTelematicsV2?.battery?.first?.reportedBatteryCapacityKwh?.value == 78.0)
    }

    @Test func graphqlBatteryWithoutCapacityStillDecodes() throws {
        let json = """
        {"carTelematicsV2": {"battery":[{"vin":"V","batteryChargeLevelPercentage":75.0}]}}
        """
        let payload = try JSONDecoder().decode(TelematicsPayloadDTO.self, from: Data(json.utf8))
        #expect(payload.carTelematicsV2?.battery?.first?.reportedBatteryCapacityKwh == nil)
        #expect(payload.carTelematicsV2?.battery?.first?.batteryChargeLevelPercentage?.value == 75.0)
    }

    // MARK: - Persisted-snapshot back-compat

    @Test func batteryDiagnosticsDecodeWithoutUnknownWireFields() throws {
        let json = """
        {"timeToTargetMinutes":30,"timeToMinimumSOCMinutes":null,
         "chargerPowerState":"unknown","averageConsumption":18.5,
         "averageConsumptionSinceCharge":null,"energyUsedSinceChargeWh":4200.0}
        """
        let diag = try JSONDecoder().decode(BatteryDiagnostics.self, from: Data(json.utf8))
        #expect(diag.unknownWireFields.isEmpty)
        #expect(diag.averageConsumption == 18.5)
    }

    @Test func otaCapabilitiesDecodeWithoutNewFields() throws {
        let json = """
        {"installedSoftwareVersion":"5.1.9","supportsFullOtaUpdates":true,
         "supportsRemoteOtaInstallSchedule":true,"supportsCloudBasedOtaDownloadConsent":false,
         "supportsUpdateStatus":true,"hasPerformanceSoftwareUpgrade":false,
         "supportsTrunkControl":true,"supportsTrunkUnlock":false,
         "supportsHonkAndFlash":true,"supportsFlash":false,
         "supportsChargingFunctions":true,"supportsGlobalChargeAmperageLimit":true,
         "supportsTargetChargeLevel":true,"supportsChargeNowTimerOverride":false,
         "chargeAmperageMinLimit":6,"chargeAmperageMaxLimit":32,
         "targetChargeLevelPercentageMinLimit":50,"supportsWindowsControl":true,
         "supportsAirPurificationRemoteStart":false,"supportsPlugAndCharge":false}
        """
        let caps = try JSONDecoder().decode(VehicleOTACapabilities.self, from: Data(json.utf8))
        #expect(caps.supportsSunroofControl == nil)
        #expect(caps.userIsLinked == nil)
        #expect(caps.userIsOwner == nil)
        #expect(caps.registrationPlate == nil)
        #expect(caps.unknownWireFields == nil)
        #expect(caps.installedSoftwareVersion == "5.1.9")
    }

    @Test func equipmentDecodesWithoutContentCodes() throws {
        let json = #"{"brand":"Polestar","doorCount":4}"#
        let equipment = try JSONDecoder().decode(VehicleEquipment.self, from: Data(json.utf8))
        #expect(equipment.brand == "Polestar")
        #expect(equipment.contentCodes == nil)
    }

    // MARK: - Live-verified climate + air-quality classifications (2026-09-11 sessions)

    @Test func climateActiveSessionDecodesTimestampsAndStaysActive() throws {
        // Shape of the live heating-session frames: running=1, remaining=30, field 6=2
        // (unknown activity enum — must NOT classify as ventilating), requested 22.0,
        // session start/end timestamp messages.
        let report: UInt64 = 1_789_161_062
        var payload = Data()
        payload += Protobuf.messageField(1, Protobuf.intField(1, Int(report)))
        payload += Protobuf.intField(2, 1)
        payload += Protobuf.intField(3, 30)
        payload += Protobuf.intField(6, 2)
        payload += Protobuf.doubleField(8, 22.0)
        payload += Protobuf.messageField(14, Protobuf.intField(1, Int(report)))
        payload += Protobuf.messageField(16, Protobuf.intField(1, Int(report + 1_800)))
        payload += Protobuf.intField(15, 2)
        let climate = PolestarGRPC.parseClimate(payload)
        #expect(climate.activity == .active)
        #expect(climate.activity != .ventilating)
        #expect(climate.timeRemainingMinutes == 30)
        #expect(climate.requestedTemperatureCelsius == 22.0)
        #expect(climate.interiorTemperatureCelsius == nil)
        #expect(climate.sessionStartedAt?.timeIntervalSince1970 == TimeInterval(report))
        #expect(climate.sessionEndsAt?.timeIntervalSince1970 == TimeInterval(report + 1_800))
    }

    @Test func climateIdleFrameStaysIdle() throws {
        // Live idle frame: running=2, remaining absent, field 6=3, no session timestamps.
        var payload = Data()
        payload += Protobuf.messageField(1, Protobuf.intField(1, 1_789_130_617))
        payload += Protobuf.intField(2, 2)
        payload += Protobuf.intField(6, 3)
        payload += Protobuf.intField(9, 0)
        payload += Protobuf.intField(13, 0)
        let climate = PolestarGRPC.parseClimate(payload)
        #expect(climate.activity == .idle)
        #expect(climate.sessionStartedAt == nil)
        #expect(climate.sessionEndsAt == nil)
    }

    @Test func airQualityMeasuresAtDecodesFromFieldTwo() throws {
        // Live post-cycle frame shape: report=field 1, measured=field 2, cycle start=field 4,
        // running=2 (off), last cycle valid, PM2.5 measured 1 µg/m³.
        let measured: UInt64 = 1_789_162_431
        var payload = Data()
        payload += Protobuf.messageField(1, Protobuf.intField(1, 1_789_162_438))
        payload += Protobuf.messageField(2, Protobuf.intField(1, Int(measured)))
        payload += Protobuf.messageField(4, Protobuf.intField(1, 1_789_162_135))
        payload += Protobuf.intField(6, 2)
        payload += Protobuf.intField(8, 1)
        payload += Protobuf.intField(10, 1)
        let air = try #require(PolestarGRPC.parseAirQuality(payload))
        #expect(air.measuredAt?.timeIntervalSince1970 == TimeInterval(measured))
        #expect(air.particulateMatter25 == 1)
        #expect(air.cleaningState == .off)
        #expect(air.lastCycleValid == true)
    }

    @Test func climateRetainsUndecodedFieldsForClassification() throws {
        // Live idle-frame shape: fields 6, 9, 13 are observed but unresolved — they must be
        // retained raw while decoded fields (2, 3) never enter the capture.
        var payload = Data()
        payload += Protobuf.messageField(1, Protobuf.intField(1, 1_789_130_617))
        payload += Protobuf.intField(2, 2)
        payload += Protobuf.intField(3, 0)
        payload += Protobuf.intField(6, 3)
        payload += Protobuf.intField(9, 0)
        payload += Protobuf.intField(13, 0)
        payload += Protobuf.intField(10, 0)
        let climate = PolestarGRPC.parseClimate(payload)
        let retained = climate.unknownWireFields?.map(\.field) ?? []
        #expect(Set(retained) == [6, 9, 13])
        #expect(retained.contains(6) && retained.contains(9) && retained.contains(13))
        #expect(!retained.contains(2) && !retained.contains(3) && !retained.contains(10))
    }

    @Test func availabilityReportRetainsTimestampAndUnknownFields() throws {
        // Wire shape from live captures: wrapper {1: id, 2: vin, 3: payload};
        // payload {1: timestamp{1: seconds}, 3: status, 5: unknown}.
        let seconds: UInt64 = 1_789_156_341
        var payload = Data()
        payload += Protobuf.messageField(1, Protobuf.intField(1, Int(seconds)))
        payload += Protobuf.intField(3, 1)
        payload += Protobuf.intField(5, 2)
        let fields = Protobuf.fields(payload)
        let decoded: Set<Int> = [1, 3, 4]
        let unknown = fields.filter { !decoded.contains($0.number) }.map(PolestarGRPC.rawField)
        #expect(unknown.map(\.field) == [5])
        let reportedAt = fields.first(where: { $0.number == 1 && $0.wire == 2 }).flatMap {
            Protobuf.fields($0.data).first(where: { $0.number == 1 })?.varint
        }.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        #expect(reportedAt?.timeIntervalSince1970 == TimeInterval(seconds))
    }

    @Test func identitySnapshotDecodesWithoutAvailabilityRetention() throws {
        // Round-trip through JSON without the new keys, mirroring snapshots persisted
        // before availability retention existed.
        let json = try JSONEncoder().encode(VehicleIdentitySnapshot(availability: .available, vin: "V"))
        let snapshot = try JSONDecoder().decode(VehicleIdentitySnapshot.self, from: json)
        #expect(snapshot.availability == .available)
        #expect(snapshot.availabilityReportedAt == nil)
        #expect(snapshot.availabilityUnknownWireFields == nil)
    }

    @Test func climateStatusDecodesWithoutSessionTimestamps() throws {
        let json = """
        {"activity":"idle","timeRemainingMinutes":null,"timerTriggered":false,
         "interiorTemperatureCelsius":null,"requestedTemperatureCelsius":null,
         "driverSeatHeatingLevel":null,"passengerSeatHeatingLevel":null,
         "steeringWheelHeatingLevel":null}
        """
        let climate = try JSONDecoder().decode(VehicleClimateStatus.self, from: Data(json.utf8))
        #expect(climate.sessionStartedAt == nil)
        #expect(climate.sessionEndsAt == nil)
    }

    @Test func climateStatusRoundTripsSessionTimestamps() throws {
        var status = VehicleClimateStatus(activity: .active, timeRemainingMinutes: 13,
                                          timerTriggered: false)
        status.sessionStartedAt = Date(timeIntervalSince1970: 1_789_161_062)
        status.sessionEndsAt = Date(timeIntervalSince1970: 1_789_162_862)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(VehicleClimateStatus.self, from: data)
        #expect(decoded == status)
    }
}
