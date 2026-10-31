import Foundation
import Testing
@testable import Hisingen

struct VehicleOTACapabilitiesGroupingTests {
    private func sample() -> VehicleOTACapabilities {
        VehicleOTACapabilities(
            installedSoftwareVersion: "4.2.13",
            identity: VehicleBackendIdentity(modelName: "XC40", modelYear: "2026", market: "SE"),
            supportsFullOtaUpdates: true,
            supportsRemoteOtaInstallSchedule: true,
            supportsCloudBasedOtaDownloadConsent: false,
            supportsUpdateStatus: true,
            hasPerformanceSoftwareUpgrade: true,
            supportsTrunkControl: true,
            supportsTrunkUnlock: false,
            supportsHonkAndFlash: true,
            supportsFlash: false,
            supportsChargingFunctions: true,
            supportsGlobalChargeAmperageLimit: true,
            supportsTargetChargeLevel: true,
            supportsChargeNowTimerOverride: false,
            chargeAmperageMinLimit: 6,
            chargeAmperageMaxLimit: 32,
            targetChargeLevelPercentageMinLimit: 50,
            supportsWindowsControl: true,
            supportsAirPurificationRemoteStart: false,
            supportsPlugAndCharge: true,
            supportsSunroofControl: true,
            userIsLinked: true,
            userIsOwner: false,
            registrationPlate: "ABC123"
        )
    }

    @Test func groupedValuesMatchFlatAccessors() {
        let caps = sample()

        #expect(caps.ota.installedSoftwareVersion == caps.installedSoftwareVersion)
        #expect(caps.ota.supportsFullOtaUpdates == caps.supportsFullOtaUpdates)
        #expect(caps.ota.supportsRemoteOtaInstallSchedule == caps.supportsRemoteOtaInstallSchedule)
        #expect(caps.ota.supportsCloudBasedOtaDownloadConsent == caps.supportsCloudBasedOtaDownloadConsent)
        #expect(caps.ota.supportsUpdateStatus == caps.supportsUpdateStatus)
        #expect(caps.ota.hasPerformanceSoftwareUpgrade == caps.hasPerformanceSoftwareUpgrade)

        #expect(caps.charging.supportsChargingFunctions == caps.supportsChargingFunctions)
        #expect(caps.charging.supportsGlobalChargeAmperageLimit == caps.supportsGlobalChargeAmperageLimit)
        #expect(caps.charging.supportsTargetChargeLevel == caps.supportsTargetChargeLevel)
        #expect(caps.charging.supportsChargeNowTimerOverride == caps.supportsChargeNowTimerOverride)
        #expect(caps.charging.supportsPlugAndCharge == caps.supportsPlugAndCharge)
        #expect(caps.charging.chargeAmperageMinLimit == caps.chargeAmperageMinLimit)
        #expect(caps.charging.chargeAmperageMaxLimit == caps.chargeAmperageMaxLimit)
        #expect(caps.charging.targetChargeLevelPercentageMinLimit == caps.targetChargeLevelPercentageMinLimit)

        #expect(caps.account.identity == caps.identity)
        #expect(caps.account.userIsLinked == caps.userIsLinked)
        #expect(caps.account.userIsOwner == caps.userIsOwner)
        #expect(caps.account.registrationPlate == caps.registrationPlate)

        #expect(caps.features.supportsTrunkControl == caps.supportsTrunkControl)
        #expect(caps.features.supportsTrunkUnlock == caps.supportsTrunkUnlock)
        #expect(caps.features.supportsHonkAndFlash == caps.supportsHonkAndFlash)
        #expect(caps.features.supportsFlash == caps.supportsFlash)
        #expect(caps.features.supportsWindowsControl == caps.supportsWindowsControl)
        #expect(caps.features.supportsAirPurificationRemoteStart == caps.supportsAirPurificationRemoteStart)
        #expect(caps.features.supportsSunroofControl == caps.supportsSunroofControl)
    }

    @Test func groupedValuesHoldInputs() {
        let caps = sample()

        #expect(caps.ota.installedSoftwareVersion == "4.2.13")
        #expect(caps.ota.supportsFullOtaUpdates)
        #expect(caps.charging.chargeAmperageMinLimit == 6)
        #expect(caps.charging.chargeAmperageMaxLimit == 32)
        #expect(caps.account.identity?.market == "SE")
        #expect(caps.account.userIsOwner == false)
        #expect(caps.account.registrationPlate == "ABC123")
    }

    @Test func settableFlatPropertiesWriteIntoFeaturesGroup() {
        var caps = VehicleOTACapabilities()
        caps.honkFlashMode = .flashOnly
        caps.controlSettings = nil
        caps.advertisedCapabilities = [.chargeTarget: true]

        #expect(caps.features.honkFlashMode == .flashOnly)
        #expect(caps.honkFlashMode == caps.features.honkFlashMode)
        #expect(caps.advertisedCapabilities == [.chargeTarget: true])
        #expect(caps.features.advertisedCapabilities == [.chargeTarget: true])
    }

    @Test func encodingRoundTripsToEqualValue() throws {
        let caps = sample()
        var withFeatures = caps
        withFeatures.honkFlashMode = .independent
        withFeatures.unknownWireFields = nil

        let data = try JSONEncoder().encode(withFeatures)
        let decoded = try JSONDecoder().decode(VehicleOTACapabilities.self, from: data)

        #expect(decoded == withFeatures)
        #expect(decoded.honkFlashMode == .independent)
        #expect(decoded.ota == withFeatures.ota)
        #expect(decoded.charging == withFeatures.charging)
        #expect(decoded.account == withFeatures.account)
    }

    @Test func encodedShapeKeepsFlatKeysWithoutGroupKeys() throws {
        let data = try JSONEncoder().encode(sample())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["supportsFullOtaUpdates"] as? Bool == true)
        #expect(object["chargeAmperageMinLimit"] as? Int == 6)
        #expect(object["registrationPlate"] as? String == "ABC123")
        #expect(object["ota"] == nil)
        #expect(object["charging"] == nil)
        #expect(object["account"] == nil)
        #expect(object["features"] == nil)
    }

    @Test func flatJSONDecodesIntoGroups() throws {
        let json = """
        {
          "installedSoftwareVersion": "5.1.9",
          "supportsFullOtaUpdates": true,
          "supportsRemoteOtaInstallSchedule": false,
          "supportsCloudBasedOtaDownloadConsent": false,
          "supportsUpdateStatus": false,
          "hasPerformanceSoftwareUpgrade": false,
          "supportsTrunkControl": false,
          "supportsTrunkUnlock": false,
          "supportsHonkAndFlash": false,
          "supportsFlash": false,
          "supportsChargingFunctions": true,
          "supportsGlobalChargeAmperageLimit": false,
          "supportsTargetChargeLevel": false,
          "supportsChargeNowTimerOverride": false,
          "chargeAmperageMinLimit": 8,
          "chargeAmperageMaxLimit": 16,
          "targetChargeLevelPercentageMinLimit": 40,
          "supportsWindowsControl": false,
          "supportsAirPurificationRemoteStart": false,
          "supportsPlugAndCharge": false,
          "userIsOwner": true
        }
        """
        let caps = try JSONDecoder().decode(VehicleOTACapabilities.self, from: Data(json.utf8))

        #expect(caps.ota.installedSoftwareVersion == "5.1.9")
        #expect(caps.ota.supportsFullOtaUpdates)
        #expect(caps.charging.supportsChargingFunctions)
        #expect(caps.charging.chargeAmperageMinLimit == 8)
        #expect(caps.charging.targetChargeLevelPercentageMinLimit == 40)
        #expect(caps.account.userIsOwner == true)
        #expect(caps.account.identity == nil)
        #expect(caps.features.supportsSunroofControl == nil)
        #expect(caps.unknownWireFields == nil)
    }

    @Test func missingRequiredFlatKeyStillFailsToDecode() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(VehicleOTACapabilities.self, from: Data("{}".utf8))
        }
    }
}
