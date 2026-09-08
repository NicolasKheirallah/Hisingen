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

// 4. Chronos errors carry record identity + action label.
require_(domain.includes("let recordID: String?"), "VehicleChronosError.recordID missing");
require_(domain.includes("var actionDisplayName"), "VehicleChronosError.actionDisplayName missing");

// 5. Provider parsers produce the new values.
const grpc = read("Sources/Hisingen/Services/API/PolestarGRPC.swift");
require_(grpc.includes("let reportedBatteryCapacityKwh: Double?"), "GrpcBatteryExtras capacity missing");
require_(grpc.includes("let unknownFields: [PolestarRawWireField]"), "GrpcBatteryExtras.unknownFields missing");
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
require_(caps.includes("recordID: recordID"), "parseErrors recordID missing");

const models = read("Sources/Hisingen/Services/API/GraphQLModels.swift");
require_(models.includes("let tokenType: String?"), "TokenResponseDTO.tokenType missing");
require_(models.includes("let idToken: String?"), "TokenResponseDTO.idToken missing");
require_(models.includes("let reportedBatteryCapacityKwh: FlexibleDouble?"), "BatteryDTO capacity missing");

// 6. Telemetry query selects capacity and flows it into state.
const telemetry = read("Sources/Hisingen/Services/API/PolestarAPI+Telemetry.swift");
require_(telemetry.includes("reportedBatteryCapacityKwh\n"), "telematics query missing capacity selection");
require_(telemetry.includes("state.reportedBatteryCapacityKwh = capacityKwh"), "capacity not wired into VehicleState");
require_(telemetry.includes("enriched.unknownWireFields = diag.unknownFields"), "unknown fields not wired into BatteryDiagnostics");

// 7. VDMS query selects packages.
const api = read("Sources/Hisingen/Services/API/PolestarAPI.swift");
require_(api.includes("packages { name }"), "VDMS packages selection missing");

// 8. UI surfaces the decodes.
const vehicleTab = read("Sources/Hisingen/UI/Vehicle/VehicleTabView.swift");
require_(vehicleTab.includes("strippedReleaseNotes"), "release-notes stripping missing");
require_(vehicleTab.includes("scheduleRelativeMinutes"), "vehicle-tab countdown row missing");
require_(vehicleTab.includes("Build code"), "vehicle-tab build-code row missing");
require_(vehicleTab.includes("Schedule originator"), "vehicle-tab originator row missing");
require_(vehicleTab.includes("actionDisplayName"), "vehicle-tab error action label missing");

const infoDiag = read("Sources/Hisingen/UI/Info/InfoTabView+Diagnostics.swift");
require_(infoDiag.includes("unknownWireFields"), "info-tab raw field rows missing");
require_(infoDiag.includes("Installs In"), "info-tab countdown row missing");

const infoCaps = read("Sources/Hisingen/UI/Info/InfoTabView+Capabilities.swift");
require_(infoCaps.includes("Sunroof Remote Control"), "capabilities sunroof row missing");
require_(infoCaps.includes("Backend Registration Plate"), "capabilities plate row missing");
require_(infoCaps.includes("Account Linked To Vehicle"), "capabilities linked row missing");
require_(infoCaps.includes("Account Owns Vehicle"), "capabilities owner row missing");

// 9. Tests exist and cover the positive controls.
const tests = read("Tests/HisingenTests/Unit/PolestarRawDecodeTests.swift");
for (const marker of [
  "batteryDecodesReportedCapacityAndKnownFields", "batteryCapturesUnknownFieldsRaw",
  "softwareDecodesDescriptionsQbAndOriginator", "schedulerIdleNegativeTwoIsNotSurfacedAsCountdown",
  "myCarsDecodesSunroofLinkedOwnerPlate", "chronosErrorsCaptureRecordIDAndVin",
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