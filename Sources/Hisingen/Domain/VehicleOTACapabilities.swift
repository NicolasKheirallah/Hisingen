import Foundation

/// `ParkingClimatization.type` (`Car` field 37.1): which directions the parked car can condition.
/// The backend ordinal is the raw value, so a value this build does not know decodes to `nil`.
enum VehicleClimatizationType: Int, Codable, Sendable {
    case unspecified = 0
    case heating = 2
    case heatingAndCooling = 3
}

/// `ParkingClimatization.heating_type` (`Car` field 37.2): which heater the parked climate
/// uses. The backend ordinal is the raw value, so a value this build does not know decodes
/// to `nil`.
enum VehicleClimatizationHeatingType: Int, Codable, Sendable {
    case unspecified = 0
    case none = 1
    case fuel = 2
    case electrical = 3
}

/// `Locks.unlock_type` (`Car` field 36.2): what a remote unlock may do. `trunkOnly` means the
/// tailgate unlocks but the doors stay locked, which is a different control, not a weaker one.
enum RemoteUnlockType: Int, Codable, Sendable {
    case unspecified = 0
    case noUnlock = 1
    case trunkOnly = 2
    case direct = 3
}

/// What Polestar's `GetMyCars` reports about one vehicle.
///
/// The fields are grouped into nested structs (`ota`, `charging`, `account`, `features`). The
/// flat properties (`supportsFullOtaUpdates`, `chargeAmperageMinLimit`, and so on) forward to
/// those groups, so call sites read the same as before.
///
/// Snapshots persist this type with the original flat keys. `Codable` is written by hand to
/// keep that shape, so older snapshots still decode and new ones stay readable by older builds.
struct VehicleOTACapabilities: Codable, Equatable, Sendable {
    let ota: OTAUpdate
    let charging: Charging
    let account: Account
    private(set) var features: Features
    /// Undecoded wire fields the `GetMyCars` response carried (top-level and inside known
    /// sub-messages), captured raw like the battery parser does. `nil` in snapshots persisted
    /// before capture existed.
    var unknownWireFields: [VehicleRawWireField]?

    struct OTAUpdate: Equatable, Sendable {
        /// The currently installed software version (e.g. "4.2.13"). This is the *authoritative*
        /// installed version from the `Car.consumerSoftwareVersion` field – `GetSoftwareInfo`
        /// does not report the installed version during a rollout, only the target.
        let installedSoftwareVersion: String?
        /// Whether the vehicle supports full OTA updates (not just minor patches).
        let supportsFullOtaUpdates: Bool
        /// Whether remote OTA install scheduling is supported (`Schedule`/`InstallNow`).
        let supportsRemoteOtaInstallSchedule: Bool
        /// Whether the vehicle supports cloud-based OTA download consent. When `false`, the
        /// download authorization cannot be triggered by a cloud API – the TCU must check in
        /// autonomously and the backend must have the VIN in the rollout cohort.
        let supportsCloudBasedOtaDownloadConsent: Bool
        /// Whether the vehicle reports update status via the `supportsUpdateStatus` flag.
        let supportsUpdateStatus: Bool
        /// Whether a performance software upgrade is available.
        let hasPerformanceSoftwareUpgrade: Bool
    }

    struct Charging: Equatable, Sendable {
        /// Whether the vehicle supports charging functions (target SOC, amp limit, timers).
        let supportsChargingFunctions: Bool
        /// Whether the vehicle supports global charge amperage limit setting.
        let supportsGlobalChargeAmperageLimit: Bool
        /// Whether the vehicle supports target charge level setting.
        let supportsTargetChargeLevel: Bool
        /// Whether the vehicle supports charge now timer override.
        let supportsChargeNowTimerOverride: Bool
        /// Whether the vehicle supports plug & charge.
        let supportsPlugAndCharge: Bool
        /// The identifier the car presents to a charger (`Charging.plug_and_charge_pcid`, wire
        /// field 20). The support flag alone is a contract claim; the pair is what proves a
        /// usable plug-and-charge setup, and the two disagree on the C3 backend.
        let plugAndChargeIdentifier: String?
        /// Minimum charge amperage limit.
        let chargeAmperageMinLimit: Int
        /// Maximum charge amperage limit.
        let chargeAmperageMaxLimit: Int
        /// Minimum target charge level percentage.
        let targetChargeLevelPercentageMinLimit: Int
    }

    struct Account: Equatable, Sendable {
        /// Backend model name, year and market for the vehicle.
        let identity: VehicleBackendIdentity?
        /// Whether this account is linked to the vehicle (`MyCar.userIsLinked`, wire field 2).
        let userIsLinked: Bool?
        /// Whether this account owns the vehicle (`MyCar.userIsOwner`, wire field 3).
        let userIsOwner: Bool?
        /// Registration plate as reported by the backend (`MyCar.registrationPlate`, wire
        /// field 4). Distinct source from the GraphQL `registrationNo`.
        let registrationPlate: String?
    }

    struct Features: Equatable, Sendable {
        var honkFlashMode: VehicleHonkFlashMode?
        var equipment: VehicleEquipment?
        var advertisedCapabilities: [VehicleCapability: Bool]?
        var controlSettings: VehicleControlSettings?
        /// Whether the vehicle supports trunk/tailgate open AND close (motorized tailgate).
        let supportsTrunkControl: Bool
        /// Whether the vehicle supports trunk unlock (unlock only, not open/close).
        let supportsTrunkUnlock: Bool
        /// Whether the vehicle supports honk and flash.
        let supportsHonkAndFlash: Bool
        /// Whether the vehicle supports flash only (without honk).
        let supportsFlash: Bool
        /// Whether the vehicle supports windows control.
        let supportsWindowsControl: Bool
        /// Whether the vehicle supports pre-cleaning.
        let supportsAirPurificationRemoteStart: Bool
        /// Whether the vehicle accepts remote sunroof open/close (`Locks.supportsSunroofControl`,
        /// wire field 36→6). Optional so persisted snapshots from before this field decode.
        let supportsSunroofControl: Bool?
        /// Which directions the parked car can condition (`ParkingClimatization.type`, wire
        /// field 37→1). `nil` when the field is absent or holds an ordinal this build does not
        /// know, so the climate card says nothing rather than guessing.
        let climatizationType: VehicleClimatizationType?
        /// Which heater the parked climate uses (`ParkingClimatization.heating_type`, wire
        /// field 37→2). `nil` when the field is absent or holds an ordinal this build does not
        /// know, so the climate card claims no heater kind.
        let climatizationHeatingType: VehicleClimatizationHeatingType?
        /// Maximum preconditioning runtime in minutes (`ParkingClimatization.max_runtime`, wire
        /// field 37→3). The app had been quoting its own constant for this.
        let climatizationMaximumRuntimeMinutes: Int?
        /// Whether the car may switch on seat and steering-wheel heating by itself during
        /// parked climate (`ParkingClimatization.supports_front_seats_and_steering_wheel_automatic`,
        /// wire field 37→12). Optional so persisted snapshots from before this field decode
        /// stay readable.
        let supportsAutomaticSeatAndWheelHeating: Bool?
    }

    init(installedSoftwareVersion: String? = nil,
         identity: VehicleBackendIdentity? = nil,
         supportsFullOtaUpdates: Bool = false,
         supportsRemoteOtaInstallSchedule: Bool = false,
         supportsCloudBasedOtaDownloadConsent: Bool = false,
         supportsUpdateStatus: Bool = false,
         hasPerformanceSoftwareUpgrade: Bool = false,
         supportsTrunkControl: Bool = false,
         supportsTrunkUnlock: Bool = false,
         supportsHonkAndFlash: Bool = false,
         supportsFlash: Bool = false,
         supportsChargingFunctions: Bool = false,
         supportsGlobalChargeAmperageLimit: Bool = false,
         supportsTargetChargeLevel: Bool = false,
         supportsChargeNowTimerOverride: Bool = false,
         chargeAmperageMinLimit: Int = 0,
         chargeAmperageMaxLimit: Int = 0,
         targetChargeLevelPercentageMinLimit: Int = 0,
         supportsWindowsControl: Bool = false,
         supportsAirPurificationRemoteStart: Bool = false,
         supportsPlugAndCharge: Bool = false,
         plugAndChargeIdentifier: String? = nil,
         supportsSunroofControl: Bool? = nil,
         climatizationType: VehicleClimatizationType? = nil,
         climatizationHeatingType: VehicleClimatizationHeatingType? = nil,
         climatizationMaximumRuntimeMinutes: Int? = nil,
         supportsAutomaticSeatAndWheelHeating: Bool? = nil,
         userIsLinked: Bool? = nil,
         userIsOwner: Bool? = nil,
         registrationPlate: String? = nil,
         unknownWireFields: [VehicleRawWireField]? = nil) {
        ota = OTAUpdate(installedSoftwareVersion: installedSoftwareVersion,
                        supportsFullOtaUpdates: supportsFullOtaUpdates,
                        supportsRemoteOtaInstallSchedule: supportsRemoteOtaInstallSchedule,
                        supportsCloudBasedOtaDownloadConsent: supportsCloudBasedOtaDownloadConsent,
                        supportsUpdateStatus: supportsUpdateStatus,
                        hasPerformanceSoftwareUpgrade: hasPerformanceSoftwareUpgrade)
        charging = Charging(supportsChargingFunctions: supportsChargingFunctions,
                            supportsGlobalChargeAmperageLimit: supportsGlobalChargeAmperageLimit,
                            supportsTargetChargeLevel: supportsTargetChargeLevel,
                            supportsChargeNowTimerOverride: supportsChargeNowTimerOverride,
                            supportsPlugAndCharge: supportsPlugAndCharge,
                            plugAndChargeIdentifier: plugAndChargeIdentifier,
                            chargeAmperageMinLimit: chargeAmperageMinLimit,
                            chargeAmperageMaxLimit: chargeAmperageMaxLimit,
                            targetChargeLevelPercentageMinLimit: targetChargeLevelPercentageMinLimit)
        account = Account(identity: identity,
                          userIsLinked: userIsLinked,
                          userIsOwner: userIsOwner,
                          registrationPlate: registrationPlate)
        features = Features(honkFlashMode: nil,
                            equipment: nil,
                            advertisedCapabilities: nil,
                            controlSettings: nil,
                            supportsTrunkControl: supportsTrunkControl,
                            supportsTrunkUnlock: supportsTrunkUnlock,
                            supportsHonkAndFlash: supportsHonkAndFlash,
                            supportsFlash: supportsFlash,
                            supportsWindowsControl: supportsWindowsControl,
                            supportsAirPurificationRemoteStart: supportsAirPurificationRemoteStart,
                            supportsSunroofControl: supportsSunroofControl,
                            climatizationType: climatizationType,
                            climatizationHeatingType: climatizationHeatingType,
                            climatizationMaximumRuntimeMinutes: climatizationMaximumRuntimeMinutes,
                            supportsAutomaticSeatAndWheelHeating: supportsAutomaticSeatAndWheelHeating)
        self.unknownWireFields = unknownWireFields
    }

    // MARK: Flat accessors

    var installedSoftwareVersion: String? { ota.installedSoftwareVersion }
    var supportsFullOtaUpdates: Bool { ota.supportsFullOtaUpdates }
    var supportsRemoteOtaInstallSchedule: Bool { ota.supportsRemoteOtaInstallSchedule }
    var supportsCloudBasedOtaDownloadConsent: Bool { ota.supportsCloudBasedOtaDownloadConsent }
    var supportsUpdateStatus: Bool { ota.supportsUpdateStatus }
    var hasPerformanceSoftwareUpgrade: Bool { ota.hasPerformanceSoftwareUpgrade }

    var supportsChargingFunctions: Bool { charging.supportsChargingFunctions }
    var supportsGlobalChargeAmperageLimit: Bool { charging.supportsGlobalChargeAmperageLimit }
    var supportsTargetChargeLevel: Bool { charging.supportsTargetChargeLevel }
    var supportsChargeNowTimerOverride: Bool { charging.supportsChargeNowTimerOverride }
    var supportsPlugAndCharge: Bool { charging.supportsPlugAndCharge }
    var plugAndChargeIdentifier: String? { charging.plugAndChargeIdentifier }
    var chargeAmperageMinLimit: Int { charging.chargeAmperageMinLimit }
    var chargeAmperageMaxLimit: Int { charging.chargeAmperageMaxLimit }
    var targetChargeLevelPercentageMinLimit: Int { charging.targetChargeLevelPercentageMinLimit }

    var identity: VehicleBackendIdentity? { account.identity }
    var userIsLinked: Bool? { account.userIsLinked }
    var userIsOwner: Bool? { account.userIsOwner }
    var registrationPlate: String? { account.registrationPlate }

    var honkFlashMode: VehicleHonkFlashMode? {
        get { features.honkFlashMode }
        set { features.honkFlashMode = newValue }
    }
    var equipment: VehicleEquipment? {
        get { features.equipment }
        set { features.equipment = newValue }
    }
    var advertisedCapabilities: [VehicleCapability: Bool]? {
        get { features.advertisedCapabilities }
        set { features.advertisedCapabilities = newValue }
    }
    var controlSettings: VehicleControlSettings? {
        get { features.controlSettings }
        set { features.controlSettings = newValue }
    }
    var supportsTrunkControl: Bool { features.supportsTrunkControl }
    var supportsTrunkUnlock: Bool { features.supportsTrunkUnlock }
    var supportsHonkAndFlash: Bool { features.supportsHonkAndFlash }
    var supportsFlash: Bool { features.supportsFlash }
    var supportsWindowsControl: Bool { features.supportsWindowsControl }
    var supportsAirPurificationRemoteStart: Bool { features.supportsAirPurificationRemoteStart }
    var supportsSunroofControl: Bool? { features.supportsSunroofControl }
    var climatizationType: VehicleClimatizationType? { features.climatizationType }
    var climatizationHeatingType: VehicleClimatizationHeatingType? { features.climatizationHeatingType }
    var climatizationMaximumRuntimeMinutes: Int? { features.climatizationMaximumRuntimeMinutes }
    var supportsAutomaticSeatAndWheelHeating: Bool? { features.supportsAutomaticSeatAndWheelHeating }

    // MARK: Codable

    /// Flat keys, matching the shape persisted before the grouping.
    private enum CodingKeys: String, CodingKey {
        case honkFlashMode, equipment, advertisedCapabilities, controlSettings, identity
        case installedSoftwareVersion, supportsFullOtaUpdates, supportsRemoteOtaInstallSchedule
        case supportsCloudBasedOtaDownloadConsent, supportsUpdateStatus, hasPerformanceSoftwareUpgrade
        case supportsTrunkControl, supportsTrunkUnlock, supportsHonkAndFlash, supportsFlash
        case supportsChargingFunctions, supportsGlobalChargeAmperageLimit, supportsTargetChargeLevel
        case supportsChargeNowTimerOverride, chargeAmperageMinLimit, chargeAmperageMaxLimit
        case targetChargeLevelPercentageMinLimit, supportsWindowsControl
        case supportsAirPurificationRemoteStart, supportsPlugAndCharge, supportsSunroofControl
        case plugAndChargeIdentifier, climatizationType, climatizationMaximumRuntimeMinutes
        case climatizationHeatingType, supportsAutomaticSeatAndWheelHeating
        case userIsLinked, userIsOwner, registrationPlate, unknownWireFields
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ota = try OTAUpdate(
            installedSoftwareVersion: c.decodeIfPresent(String.self, forKey: .installedSoftwareVersion),
            supportsFullOtaUpdates: c.decode(Bool.self, forKey: .supportsFullOtaUpdates),
            supportsRemoteOtaInstallSchedule: c.decode(Bool.self, forKey: .supportsRemoteOtaInstallSchedule),
            supportsCloudBasedOtaDownloadConsent: c.decode(Bool.self, forKey: .supportsCloudBasedOtaDownloadConsent),
            supportsUpdateStatus: c.decode(Bool.self, forKey: .supportsUpdateStatus),
            hasPerformanceSoftwareUpgrade: c.decode(Bool.self, forKey: .hasPerformanceSoftwareUpgrade)
        )
        charging = try Charging(
            supportsChargingFunctions: c.decode(Bool.self, forKey: .supportsChargingFunctions),
            supportsGlobalChargeAmperageLimit: c.decode(Bool.self, forKey: .supportsGlobalChargeAmperageLimit),
            supportsTargetChargeLevel: c.decode(Bool.self, forKey: .supportsTargetChargeLevel),
            supportsChargeNowTimerOverride: c.decode(Bool.self, forKey: .supportsChargeNowTimerOverride),
            supportsPlugAndCharge: c.decode(Bool.self, forKey: .supportsPlugAndCharge),
            plugAndChargeIdentifier: c.decodeIfPresent(String.self, forKey: .plugAndChargeIdentifier),
            chargeAmperageMinLimit: c.decode(Int.self, forKey: .chargeAmperageMinLimit),
            chargeAmperageMaxLimit: c.decode(Int.self, forKey: .chargeAmperageMaxLimit),
            targetChargeLevelPercentageMinLimit: c.decode(Int.self, forKey: .targetChargeLevelPercentageMinLimit)
        )
        account = try Account(
            identity: c.decodeIfPresent(VehicleBackendIdentity.self, forKey: .identity),
            userIsLinked: c.decodeIfPresent(Bool.self, forKey: .userIsLinked),
            userIsOwner: c.decodeIfPresent(Bool.self, forKey: .userIsOwner),
            registrationPlate: c.decodeIfPresent(String.self, forKey: .registrationPlate)
        )
        features = try Features(
            honkFlashMode: c.decodeIfPresent(VehicleHonkFlashMode.self, forKey: .honkFlashMode),
            equipment: c.decodeIfPresent(VehicleEquipment.self, forKey: .equipment),
            advertisedCapabilities: c.decodeIfPresent([VehicleCapability: Bool].self, forKey: .advertisedCapabilities),
            controlSettings: c.decodeIfPresent(VehicleControlSettings.self, forKey: .controlSettings),
            supportsTrunkControl: c.decode(Bool.self, forKey: .supportsTrunkControl),
            supportsTrunkUnlock: c.decode(Bool.self, forKey: .supportsTrunkUnlock),
            supportsHonkAndFlash: c.decode(Bool.self, forKey: .supportsHonkAndFlash),
            supportsFlash: c.decode(Bool.self, forKey: .supportsFlash),
            supportsWindowsControl: c.decode(Bool.self, forKey: .supportsWindowsControl),
            supportsAirPurificationRemoteStart: c.decode(Bool.self, forKey: .supportsAirPurificationRemoteStart),
            supportsSunroofControl: c.decodeIfPresent(Bool.self, forKey: .supportsSunroofControl),
            climatizationType: c.decodeIfPresent(VehicleClimatizationType.self, forKey: .climatizationType),
            climatizationHeatingType: c.decodeIfPresent(VehicleClimatizationHeatingType.self, forKey: .climatizationHeatingType),
            climatizationMaximumRuntimeMinutes: c.decodeIfPresent(Int.self, forKey: .climatizationMaximumRuntimeMinutes),
            supportsAutomaticSeatAndWheelHeating: c.decodeIfPresent(Bool.self, forKey: .supportsAutomaticSeatAndWheelHeating)
        )
        unknownWireFields = try c.decodeIfPresent([VehicleRawWireField].self, forKey: .unknownWireFields)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(features.honkFlashMode, forKey: .honkFlashMode)
        try c.encodeIfPresent(features.equipment, forKey: .equipment)
        try c.encodeIfPresent(features.advertisedCapabilities, forKey: .advertisedCapabilities)
        try c.encodeIfPresent(features.controlSettings, forKey: .controlSettings)
        try c.encodeIfPresent(account.identity, forKey: .identity)
        try c.encodeIfPresent(ota.installedSoftwareVersion, forKey: .installedSoftwareVersion)
        try c.encode(ota.supportsFullOtaUpdates, forKey: .supportsFullOtaUpdates)
        try c.encode(ota.supportsRemoteOtaInstallSchedule, forKey: .supportsRemoteOtaInstallSchedule)
        try c.encode(ota.supportsCloudBasedOtaDownloadConsent, forKey: .supportsCloudBasedOtaDownloadConsent)
        try c.encode(ota.supportsUpdateStatus, forKey: .supportsUpdateStatus)
        try c.encode(ota.hasPerformanceSoftwareUpgrade, forKey: .hasPerformanceSoftwareUpgrade)
        try c.encode(features.supportsTrunkControl, forKey: .supportsTrunkControl)
        try c.encode(features.supportsTrunkUnlock, forKey: .supportsTrunkUnlock)
        try c.encode(features.supportsHonkAndFlash, forKey: .supportsHonkAndFlash)
        try c.encode(features.supportsFlash, forKey: .supportsFlash)
        try c.encode(charging.supportsChargingFunctions, forKey: .supportsChargingFunctions)
        try c.encode(charging.supportsGlobalChargeAmperageLimit, forKey: .supportsGlobalChargeAmperageLimit)
        try c.encode(charging.supportsTargetChargeLevel, forKey: .supportsTargetChargeLevel)
        try c.encode(charging.supportsChargeNowTimerOverride, forKey: .supportsChargeNowTimerOverride)
        try c.encode(charging.chargeAmperageMinLimit, forKey: .chargeAmperageMinLimit)
        try c.encode(charging.chargeAmperageMaxLimit, forKey: .chargeAmperageMaxLimit)
        try c.encode(charging.targetChargeLevelPercentageMinLimit, forKey: .targetChargeLevelPercentageMinLimit)
        try c.encode(features.supportsWindowsControl, forKey: .supportsWindowsControl)
        try c.encode(features.supportsAirPurificationRemoteStart, forKey: .supportsAirPurificationRemoteStart)
        try c.encode(charging.supportsPlugAndCharge, forKey: .supportsPlugAndCharge)
        try c.encodeIfPresent(charging.plugAndChargeIdentifier, forKey: .plugAndChargeIdentifier)
        try c.encodeIfPresent(features.supportsSunroofControl, forKey: .supportsSunroofControl)
        try c.encodeIfPresent(features.climatizationType, forKey: .climatizationType)
        try c.encodeIfPresent(features.climatizationHeatingType, forKey: .climatizationHeatingType)
        try c.encodeIfPresent(features.climatizationMaximumRuntimeMinutes,
                              forKey: .climatizationMaximumRuntimeMinutes)
        try c.encodeIfPresent(features.supportsAutomaticSeatAndWheelHeating,
                              forKey: .supportsAutomaticSeatAndWheelHeating)
        try c.encodeIfPresent(account.userIsLinked, forKey: .userIsLinked)
        try c.encodeIfPresent(account.userIsOwner, forKey: .userIsOwner)
        try c.encodeIfPresent(account.registrationPlate, forKey: .registrationPlate)
        try c.encodeIfPresent(unknownWireFields, forKey: .unknownWireFields)
    }
}
