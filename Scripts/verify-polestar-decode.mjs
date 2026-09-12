#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = p => fs.readFileSync(path.join(root, p), "utf8");
const failures = [];
const require_ = (cond, msg) => { if (!cond) failures.push(msg); };

// 1. Domain capture type exists and is Codable (persisted snapshots).
const domain = read("Sources/Hisingen/Domain/VehicleDomainTypes.swift");
require_(domain.includes("struct PolestarRawWireField"), "PolestarRawWireField missing in domain");
require_(domain.includes("var unknownWireFields: [PolestarRawWireField]"), "BatteryDiagnostics.unknownWireFields missing");

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
const grpc = read("Sources/Hisingen/Services/API/PolestarGRPC.swift");
require_(grpc.includes("let reportedBatteryCapacityKwh: Double?"), "GrpcBatteryExtras capacity missing");
require_(grpc.includes("let unknownFields: [PolestarRawWireField]"), "GrpcBatteryExtras.unknownFields missing");
require_(grpc.includes("capacityKwh = Protobuf.double(from: field.data)"), "battery wire field 12 (capacity) parse missing");
require_(grpc.includes("static let unmappedBatteryFields"), "unmappedBatteryFields set missing");
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
//    through the gRPC battery parse and the equipment fallback via resolvedBatteryCapacity.
const telemetry = read("Sources/Hisingen/Services/API/PolestarAPI+Telemetry.swift");
const queryStart = telemetry.indexOf("static func telematicsQuery");
const queryEnd = telemetry.indexOf("static func matchingReading");
require_(queryStart >= 0 && queryEnd > queryStart, "telematicsQuery builder not found");
require_(!telemetry.slice(queryStart, queryEnd).includes("reportedBatteryCapacityKwh"),
  "telematics query must not re-select the schema-removed capacity field");
require_(telemetry.includes("static func resolvedBatteryCapacity(graphQL: Double?, batteryService: Double?, equipment: VehicleEquipment?)"),
  "capacity resolution missing gRPC/equipment path");
require_(telemetry.includes("state.energy.reportedBatteryCapacityKwh = capacityKwh"), "capacity not wired into VehicleState");
require_(telemetry.includes("enriched.unknownWireFields = diag.unknownFields"), "unknown fields not wired into BatteryDiagnostics");

// 6. VDMS query is limited to fields the production schema reliably returns.
const api = read("Sources/Hisingen/Services/API/PolestarAPI.swift");
const vdmsStart = api.indexOf('query GetVDMSCars');
const vdmsEnd = api.indexOf('let body: [String: Any]', vdmsStart);
require_(vdmsStart >= 0 && vdmsEnd > vdmsStart, "VDMS query not found");
const vdmsQuery = api.slice(vdmsStart, vdmsEnd);
for (const field of ["exterior", "interior", "wheels", "packages"]) {
  require_(!vdmsQuery.includes(field), `unsupported VDMS ${field} selection remains`);
}

// 7. UI surfaces the decodes.
const vehicleTab = read("Sources/Hisingen/UI/Vehicle/VehicleTabView.swift");
require_(vehicleTab.includes("strippedReleaseNotes"), "release-notes stripping missing");
require_(vehicleTab.includes("scheduleRelativeMinutes"), "vehicle-tab countdown row missing");
require_(vehicleTab.includes("Build code"), "vehicle-tab build-code row missing");
require_(vehicleTab.includes("Schedule originator"), "vehicle-tab originator row missing");

const infoDiag = read("Sources/Hisingen/UI/Info/InfoTabView+Diagnostics.swift");
require_(infoDiag.includes("unknownWireFields"), "info-tab raw field rows missing");
require_(infoDiag.includes("Installs In"), "info-tab countdown row missing");

const infoCaps = read("Sources/Hisingen/UI/Info/InfoTabView+Capabilities.swift");
require_(infoCaps.includes("Sunroof Remote Control"), "capabilities sunroof row missing");
require_(infoCaps.includes("Backend Registration Plate"), "capabilities plate row missing");
require_(infoCaps.includes("Account Linked To Vehicle"), "capabilities linked row missing");
require_(infoCaps.includes("Account Owns Vehicle"), "capabilities owner row missing");
require_(infoCaps.includes("Undecoded Backend Fields"), "capabilities raw-field disclosure missing");
require_(infoCaps.includes("rawCapabilityFieldRow"), "capabilities raw-field row builder missing");

// 8. Tests exist and cover the positive controls.
const tests = read("Tests/HisingenTests/Unit/PolestarRawDecodeTests.swift");
for (const marker of [
  "batteryDecodesReportedCapacityAndKnownFields", "batteryCapturesUnknownFieldsRaw",
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

if (failures.length) {
  console.error(`FAIL (${failures.length}):\n` + failures.map(f => `  - ${f}`).join("\n"));
  process.exit(1);
}
console.log("all decode markers present");
