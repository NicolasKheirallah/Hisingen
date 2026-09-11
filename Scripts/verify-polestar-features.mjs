#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = p => fs.readFileSync(path.join(root, p), "utf8");
const failures = [];
const require_ = (cond, msg) => { if (!cond) failures.push(msg); };

// F1: Factory passport export
const specs = read("Sources/Hisingen/UI/Info/InfoTabView+Specs.swift");
require_(specs.includes("static func factoryPassportCSV"), "factoryPassportCSV builder missing");
require_(specs.includes("Export Factory Passport (CSV)"), "factory passport UI entry missing");
for (const field of ["VIN", "Nickname", "Model", "Registration No", "Internal Vehicle ID",
                     "Factory Spec (PNO34)", "Factory Build Week", "Market",
                     "Exterior Paint", "Upholstery"]) {
  require_(specs.includes(`"${field}"`), `passport CSV missing row: ${field}`);
}
require_(!specs.includes('["Wheels",'), "unsupported wheel row remains in passport CSV");
require_(!specs.includes('["Factory Packages",'), "unsupported package row remains in passport CSV");

// F2: Charging curve chart (shipped implementation verified wired)
const historyCharging = read("Sources/Hisingen/UI/History/HistoryDashboardView+Charging.swift");
const historyMain = read("Sources/Hisingen/UI/History/HistoryDashboardView.swift");
require_(historyCharging.includes("var chargingCurveCard"), "chargingCurveCard missing");
require_(historyCharging.includes("Charging Curve"), "charging-curve card title missing");
require_(historyCharging.includes("powerKw"), "charging curve power series missing");
require_(historyMain.includes("if selectedSession != nil && !selectedSessionCurve.isEmpty { chargingCurveCard }"),
  "charging curve not presented in history");

// F3: AQI one-tap pre-clean
const location = read("Sources/Hisingen/UI/Info/InfoTabView+Location.swift");
require_(location.includes("Clean Cabin Air (PM2.5 Pre-Clean)"), "AQI pre-clean button missing");
require_(location.includes("onRemoteCommand(air.cleaningState == .on ? .stopPreCleaning : .startPreCleaning)"),
  "AQI pre-clean not wired to RemoteCommand");
require_(location.includes("canTogglePreCleaning"), "pre-clean availability guard missing");
const domainTypes = read("Sources/Hisingen/Domain/VehicleDomainTypes.swift");
require_(domainTypes.includes("var canTogglePreCleaning: Bool"), "VehicleAirQuality.canTogglePreCleaning missing");
const infoMain = read("Sources/Hisingen/UI/Info/InfoTabView.swift");
require_(infoMain.includes("var onRemoteCommand: (RemoteCommand) -> Void"), "InfoTabView.onRemoteCommand missing");
const contentView = read("Sources/Hisingen/UI/Shell/HisingenContentView.swift");
require_(contentView.includes("onRemoteCommand: onRemoteCommand)"), "InfoTabView not wired to shell command path");

// F4: Cabin thermal matrix
require_(fs.existsSync(path.join(root, "Sources/Hisingen/UI/Components/CabinThermalMatrix.swift")),
  "CabinThermalMatrix.swift missing");
const matrix = read("Sources/Hisingen/UI/Components/CabinThermalMatrix.swift");
for (const marker of ["Driver Seat", "Passenger Seat", "Steering Wheel",
                      "driverSeatLevel", "passengerSeatLevel", "steeringWheelLevel",
                      "interiorTemperatureCelsius", "requestedTemperatureCelsius"]) {
  require_(matrix.includes(marker), `CabinThermalMatrix missing: ${marker}`);
}
require_(specs.includes("CabinThermalMatrix("), "thermal matrix not embedded in interior card");

// F5: Owner gate
const gate = read("Sources/Hisingen/Domain/CapabilityGate.swift");
require_(gate.includes("case notVehicleOwner"), "CommandAvailability.notVehicleOwner missing");
require_(gate.includes("state.accountOwnsVehicle != false"), "owner check not in CapabilityGate");
const stateSrc = read("Sources/Hisingen/Domain/VehicleState.swift");
require_(stateSrc.includes("var accountOwnsVehicle: Bool?"), "VehicleState.accountOwnsVehicle missing");
const coordinator = read("Sources/Hisingen/Services/Coordination/CommandCoordinator.swift");
require_(coordinator.includes("case .notVehicleOwner:"), "coordinator does not handle notVehicleOwner");
const tests = read("Tests/HisingenTests/Unit/PolestarFeatureWiringTests.swift");
for (const marker of [
  "factoryPassportCSVCoversAllIdentityFields", "factoryPassportCSVEscapesCommasAndQuotes",
  "ownerGateBlocksWhenExplicitlyFalse", "ownerGateAllowsUnknownOwnership",
  "preCleanToggleAvailabilityFollowsReportedState", "thermalMatrixAccessibilitySummaryListsActiveHeaters"
]) {
  require_(tests.includes(marker), `test missing: ${marker}`);
}

if (failures.length) {
  console.error(`FAIL (${failures.length}):\n` + failures.map(f => `  - ${f}`).join("\n"));
  process.exit(1);
}
console.log("all feature markers present");
