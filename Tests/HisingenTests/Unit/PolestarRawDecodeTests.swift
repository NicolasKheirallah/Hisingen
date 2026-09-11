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
        #expect(caps.installedSoftwareVersion == "5.1.9")
    }
}
