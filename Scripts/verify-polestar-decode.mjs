#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = p => fs.readFileSync(path.join(root, p), "utf8");
const failures = [];
const require_ = (cond, msg) => { if (!cond) failures.push(msg); };

// 1. Domain capture type exists and is Codable (persisted snapshots).
const domain = ["VehicleDomainTypes", "VehicleRawWireField", "VehicleOTACapabilities"]
  .map(name => read(`Sources/Hisingen/Domain/${name}.swift`)).join("\n");
require_(domain.includes("struct VehicleRawWireField"), "VehicleRawWireField missing in domain");
require_(domain.includes("var unknownWireFields: [VehicleRawWireField]"), "BatteryDiagnostics.unknownWireFields missing");

// 2. Software info carries the newly decoded fields.
for (const field of ["qbCode", "originator", "shortDescription", "longDescription", "scheduleRelativeMinutes"]) {
  require_(domain.includes(`var ${field}: String? = nil`) || domain.includes(`var ${field}: Int? = nil`),
    `VehicleSoftwareInfo.${field} missing`);
}

// 3. OTA capabilities carry sunroof/link/owner/plate.
for (const field of ["supportsSunroofControl", "userIsLinked", "userIsOwner", "registrationPlate"]) {
  require_(domain.includes(`let ${field}: Bool?`) || domain.includes(`let ${field}: String?`),
    `VehicleOTACapabilities.${field} missing`);
}

// 4. Provider parsers produce the new values.
const grpc = ["Services/API/PolestarGRPC.swift", "Domain/VehicleBatteryReading.swift"]
  .map(file => read(`Sources/Hisingen/${file}`)).join("\n");
require_(grpc.includes("let reportedBatteryCapacityKwh: Double?"), "GrpcBatteryExtras capacity missing");
require_(grpc.includes("let unknownFields: [VehicleRawWireField]"), "GrpcBatteryExtras.unknownFields missing");
require_(!grpc.includes("static let capacityKwh = 12"), "ambiguous battery field 12 must not be capacity");
require_(grpc.includes("reportedBatteryCapacityKwh: nil"), "C3 battery must not report unverified capacity");
require_(grpc.includes("static let rangeMiles = 8"), "battery miles fallback missing");
require_(grpc.includes("energyUsedManualTripWh: manualEnergy"), "manual-trip energy missing");
require_(grpc.includes("energyUsedAutomaticTripWh: automaticEnergy"), "automatic-trip energy missing");
require_(grpc.includes("usageMode: usageMode"), "availability usage mode missing");
require_(grpc.includes("static let decodedBatteryFields"), "decodedBatteryFields set missing");
require_(grpc.includes("static func rawField("), "rawField capture missing");
require_(grpc.includes("Transport error"), "availability reason 7 missing");
require_(grpc.includes("Unknown reason (%d)"), "availability unknown-reason passthrough missing");

const caps = read("Sources/Hisingen/Services/API/PolestarGRPCCapabilities.swift");
require_(caps.includes("qbCode:"), "parseSoftware qbCode missing");
require_(caps.includes("originator:"), "parseSoftware originator missing");
require_(caps.includes("shortDescription:"), "parseSoftware shortDescription missing");
require_(caps.includes("longDescription:"), "parseSoftware longDescription missing");
require_(caps.includes("scheduleRelativeMinutes: relativeMinutes"), "scheduler relativeMinutes wiring missing");
require_(caps.includes("supportsSunroofControl: supportsSunroofControl"), "parseMyCars sunroof missing");
require_(caps.includes("userIsLinked:"), "parseMyCars userIsLinked missing");
require_(caps.includes("userIsOwner:"), "parseMyCars userIsOwner missing");
require_(caps.includes("registrationPlate:"), "parseMyCars registrationPlate missing");
require_(caps.includes("static let decodedCarFields"), "GetMyCars known-field set missing");
require_(caps.includes("static let decodedNestedCarFields"), "GetMyCars nested known-field set missing");
require_(caps.includes("static func unknownCapabilityFields"), "GetMyCars unknown-field retention missing");
require_(caps.includes("capabilities.unknownWireFields = unknownCapabilityFields(car)"), "retained fields not wired into capabilities");
require_(caps.includes("result.contentCodes = contentCodes.split"), "car field 47 content-code parse missing");
const equipmentSource = read("Sources/Hisingen/Domain/VehicleEquipment.swift");
require_(equipmentSource.includes("static func contentCodeLabel"), "visual-id group labels missing");
require_(equipmentSource.includes('L10n.text("Grille Variant")'), "grille variant group not named");
require_(equipmentSource.includes('L10n.text("Model Year")'), "model year group not named");
const specsSource = read("Sources/Hisingen/UI/Info/InfoTabView+Specs.swift");
require_(specsSource.includes("factoryContentCodes"), "visual-id groups not shown on the specs card");
require_(caps.includes("result.grossVehicleWeightRatingKg = numeric(car, 44)"), "car field 44 gross vehicle weight parse missing");
require_(caps.includes("switch intValue(locksData, 1)"), "Locks.lock_type capability gate missing");
require_(caps.includes("advertised[.reducedGuardLock] = true"), "reduced-guard lock not wired from lock_type");
require_(caps.includes("switch intValue(chargingData, 10)"), "Charging.charge_timer_type gate missing");
require_(caps.includes("advertised[.chargeLocations] = true"), "charge locations not wired from charge_timer_type");
require_(caps.includes("switch intValue(climate, 1)"), "ParkingClimatization.type gate missing");
require_(caps.includes("switch unlockType {"), "Locks.unlock_type gate missing");
require_(caps.includes("advertised[.remoteUnlock] = false"), "remote unlock not gated from unlock_type");
require_(caps.includes("supportsTrunkUnlock || unlockType == .trunkOnly"), "trunk-only unlock does not keep the trunk control");
require_(caps.includes("string(chargingData ?? [], 20)"), "Charging.plug_and_charge_pcid parse missing");
require_(caps.includes("climatizationType: intValue(climate, 1)"), "climatization type not decoded into the capabilities");
require_(caps.includes("settings.timersPerLocationMaximum = positiveInt(varint(chargingData ?? [], 13))"), "per-location timer limit missing");
require_(caps.includes("settings.departureTimesPerLocationMaximum"), "per-location departure limit missing");
require_(caps.includes("sessionStartedAt: sessionStartedAt"), "parseClimate session start missing");
require_(caps.includes("sessionEndsAt: sessionEndsAt"), "parseClimate session end missing");
require_(caps.includes("measuredAt: timestamp(message(fields, field: 2))"), "parseAirQuality field-2 measurement time missing");
require_(!/if \(varint\(fields, 6\) \?\? 0\) != 0 \{[\s\S]{0,80}ventilating/.test(caps), "field 6 must not be read as a ventilation flag");
require_(!caps.includes("ErrorService/GetErrors"), "removed Chronos error endpoint is still present");
require_(!caps.includes("fetchErrors("), "removed Chronos error fetch is still present");
require_(!caps.includes("parseErrors("), "removed Chronos error parser is still present");

const models = read("Sources/Hisingen/Services/API/GraphQLModels.swift");
require_(models.includes("let tokenType: String?"), "TokenResponseDTO.tokenType missing");
require_(models.includes("let idToken: String?"), "TokenResponseDTO.idToken missing");
// Decode-tolerance only: the query no longer selects this field, but the DTO still accepts
// it if Polestar ever returns it (pinned by PolestarRawDecodeTests).
require_(models.includes("let reportedBatteryCapacityKwh: FlexibleDouble?"), "BatteryDTO capacity missing");

// 5. Telemetry query must NOT re-select the capacity field Polestar removed from its schema
//    (GraphQL rejects the whole carTelematicsV2 selection otherwise). Capacity instead flows
//    through explicit capacity metadata and equipment via resolvedBatteryCapacity.
const telemetry = ["PolestarAPI+Telemetry", "PolestarConsumerSnapshotAssembler"]
  .map(name => read(`Sources/Hisingen/Services/API/${name}.swift`)).join("\n");
const queryStart = telemetry.indexOf("static func telematicsQuery");
const queryEnd = telemetry.indexOf("static func matchingReading");
require_(queryStart >= 0 && queryEnd > queryStart, "telematicsQuery builder not found");
require_(!telemetry.slice(queryStart, queryEnd).includes("reportedBatteryCapacityKwh"),
  "telematics query must not re-select the schema-removed capacity field");
require_(telemetry.includes("static func resolvedBatteryCapacity(graphQL: Double?, batteryService: Double?, equipment: VehicleEquipment?)"),
  "capacity resolution missing gRPC/equipment path");
require_(telemetry.includes("state.energy.reportedBatteryCapacityKwh = capacityKwh"), "capacity not wired into VehicleState");
require_(telemetry.includes("enriched.unknownWireFields = diag.unknownFields"), "unknown fields not wired into BatteryDiagnostics");
require_(telemetry.includes("usageMode: availabilityReport.usageMode"), "usage mode not wired into identity");

// 6. VDMS query is limited to fields the production schema reliably returns.
const api = read("Sources/Hisingen/Services/API/PolestarAPI.swift");
const vdmsQuery = api.match(/let query = """\s*(query GetVDMSCars\b[\s\S]*?)"""/)?.[1] ?? "";
require_(vdmsQuery.length > 0, "VDMS query not found");
for (const field of ["exterior", "interior", "wheels", "packages"]) {
  require_(!vdmsQuery.includes(field), `unsupported VDMS ${field} selection remains`);
}

// 7. UI surfaces the decodes.
const softwareCard = read("Sources/Hisingen/UI/Vehicle/VehicleSoftwareCard.swift");
require_(softwareCard.includes("strippedReleaseNotes"), "release-notes stripping missing");
require_(softwareCard.includes("scheduleRelativeMinutes"), "vehicle-tab countdown row missing");
require_(softwareCard.includes("Build code"), "vehicle-tab build-code row missing");
require_(softwareCard.includes("Schedule originator"), "vehicle-tab originator row missing");

const infoDiag = read("Sources/Hisingen/UI/Info/InfoTabView+Diagnostics.swift");
require_(infoDiag.includes("unknownWireFields"), "info-tab raw field rows missing");
require_(infoDiag.includes("Installs In"), "info-tab countdown row missing");

const infoCaps = read("Sources/Hisingen/UI/Info/InfoTabView+Capabilities.swift");
require_(infoCaps.includes("Sunroof Remote Control"), "capabilities sunroof row missing");
require_(infoCaps.includes("Backend Registration Plate"), "capabilities plate row missing");
require_(infoCaps.includes("Account Linked To Vehicle"), "capabilities linked row missing");
require_(infoCaps.includes("Account Owns Vehicle"), "capabilities owner row missing");
require_(infoCaps.includes("Unwired Backend Fields"), "capabilities raw-field disclosure missing");
require_(infoCaps.includes("rawCapabilityFieldRow"), "capabilities raw-field row builder missing");

// 8. Tests exist and cover the positive controls.
const tests = read("Tests/HisingenTests/Unit/PolestarRawDecodeTests.swift");
for (const marker of [
  "batteryQuarantinesCapacityAndDecodesKnownFields", "batteryCapturesUnknownFieldsRaw",
  "softwareDecodesDescriptionsQbAndOriginator", "schedulerIdleNegativeTwoIsNotSurfacedAsCountdown",
  "myCarsDecodesSunroofLinkedOwnerPlate", "myCarsRetainsUnknownFieldsRawAndDecodesContentCodes",
  "climateActiveSessionDecodesTimestampsAndStaysActive", "airQualityMeasuresAtDecodesFromFieldTwo",
  "climateIdleFrameStaysIdle", "climateStatusDecodesWithoutSessionTimestamps",
  "myCarsWithOnlyKnownFieldsRetainsNothing", "equipmentDecodesWithoutContentCodes",
  "tokenResponseDecodesTokenTypeAndIdToken", "graphqlBatteryCapacityDecodesNumberAndString",
  "otaCapabilitiesDecodeWithoutNewFields", "batteryDiagnosticsDecodeWithoutUnknownWireFields"
]) {
  require_(tests.includes(marker), `test missing: ${marker}`);
}

// 9. The enum-driven capability gates keep their tests.
const wiringTests = read("Tests/HisingenTests/Unit/PolestarFeatureWiringTests.swift");
for (const marker of [
  "myCarsLockTypeGatesLocksAndReducedGuard", "myCarsChargeTimerTypeGatesSchedulesAndLocations",
  "myCarsClimatizationTypeGatesClimateStart", "equipmentShowsGrossVehicleWeight",
  "myCarsUnlockTypeGatesRemoteUnlockAndTrunk", "myCarsPlugAndChargeNeedsTheIdentifierPair",
  "myCarsClimatizationTypeAndRuntimeReachTheCard", "myCarsPerLocationLimitsReachTheControlSettings",
  "visualIdentityNamesTheVerifiedGroupsOnly"
]) {
  require_(wiringTests.includes(marker), `wiring test missing: ${marker}`);
}

// 10. The UI that consumes these fields: honest labels, no claim the wire does not back.
const infoCapabilities = read("Sources/Hisingen/UI/Info/InfoTabView+Capabilities.swift");
for (const [marker, note] of [
  ["L10n.format(\"Unwired Backend Fields (%d)\"", "capability raw list still labelled undecoded"],
  ["caps.plugAndChargeIdentifier == nil", "plug and charge row ignores the missing identifier"],
  ["L10n.text(\"Backend Control Settings\")", "per-location limits not shown in the capability inspector"]
]) {
  require_(infoCapabilities.includes(marker), `capability UI marker missing (${note})`);
}
const specs = read("Sources/Hisingen/UI/Info/InfoTabView+Specs.swift");
require_(specs.includes('grossVehicleWeightRatingKg, weight > 0'), "specs card weight row missing from the specs rows");
const climateCard = read("Sources/Hisingen/UI/Controls/ClimateControlCard.swift");
require_(climateCard.includes('L10n.format("Runs up to %d min"'), "climate card does not state the reported runtime");
require_(climateCard.includes("private var climatizationNote"), "climate card type note missing");
const accessCard = read("Sources/Hisingen/UI/Controls/AccessControlsCard.swift");
require_(accessCard.includes("lockAvailability.shortReason"), "lock button promises an action the car refuses");

if (failures.length) {
  console.error(`FAIL (${failures.length}):\n` + failures.map(f => `  - ${f}`).join("\n"));
  process.exit(1);
}
console.log("all decode markers present");
