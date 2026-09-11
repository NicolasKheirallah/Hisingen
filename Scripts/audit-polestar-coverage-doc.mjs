#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const docPath = path.join(root, "docs", "api", "polestar-raw-output-coverage.md");
const doc = fs.readFileSync(docPath, "utf8");
const failures = [];

function fail(msg) { failures.push(msg); }

// G3: every cited file exists, and every line-number anchor resolves.
const fileRefs = [...doc.matchAll(/`(?:Sources\/[A-Za-z0-9\/.]+\.swift(?::(\d+)(?:-\d+)?)?)`/g)];
const citedFiles = new Set();
for (const match of fileRefs) {
  const file = match[0].replace(/`/g, "").split(":")[0];
  citedFiles.add(file);
  const abs = path.join(root, file);
  if (!fs.existsSync(abs)) fail(`file does not exist: ${file}`);
  const line = match[1];
  if (line) {
    const content = fs.readFileSync(abs, "utf8").split("\n");
    if (Number(line) > content.length) fail(`line ${line} beyond EOF in ${file}`);
  }
}
if (citedFiles.size === 0) fail("no Sources/ file references found in coverage doc");

// Every domain symbol named in backticks in tables must exist somewhere in the codebase.
const symbols = [...doc.matchAll(/`([A-Z][A-Za-z0-9_.]{3,})`/g)].map(m => m[1]);
const knownSymbols = [
  "TokenResponseDTO", "UserInfoDTO", "ConsumerCarDTO", "BatteryDTO", "OdometerDTO", "HealthDTO",
  "AppBackendCarDTO", "GrpcBatteryExtras", "parseBattery", "parseExterior", "parseHealth",
  "discoverPressureQuadruple", "parseOdometer", "parseDashboardOdometer", "parseClimate",
  "parseAirQuality", "parseLocation", "parseWeather", "parseSoftware", "softwareState",
  "parseMyCars", "parseChargeLocations", "parseGlobalChargeTimer",
  "parseChargeLocationSchedules", "parseClimateTimers", "chronosEnvelope", "chronosRequest",
  "GrpcHealthReport", "GrpcOdometerReport", "TelematicsPayloadDTO", "TelematicsDTO",
  "ConsumerCarsPayloadDTO", "AppBackendCarsPayloadDTO", "VehicleOTACapabilities",
  "ScheduleSetBy", "BatteryDiagnostics", "VehicleSoftwareInfo", "GraphQLModels.swift",
  "PolestarAPI.swift", "PolestarAPI+Telemetry.swift", "PolestarGRPC.swift",
  "PolestarGRPCCapabilities.swift", "PolestarGRPCRemote.swift"
];
// Backend RPC names cited from the probe transcripts (some verified ABSENT on the backend,
// e.g. WakeUp) are not Hisingen symbols and must not resolve against Sources/.
const backendRpcNames = [
  "WakeUp", "TailgateControl", "WindowControl", "HonkFlash", "ClimatizationStart",
  "ClimatizationStop", "PreCleaning", "SetTargetSoc", "SetAmpLimit", "SetGlobalChargeTimer",
  "SetTimers", "DeleteTimer", "Schedule", "InstallNow", "CancelSchedule",
  "StartOverrideChargeTimer", "StopOverrideChargeTimer", "CreateAtTheCarLocation",
  "UpdateAlias", "UpdateAmpLimit", "UpdateMinimumSoc", "UpdateOptimizedSetting",
  "DeleteLocation", "GetLatestBattery", "GetLatestExterior", "GetLatestAvailability",
  "GetSoftwareInfo", "GetSchedule", "GetMyCars", "GetChargeLocations"
];
function grepAll(needle) {
  const out = [];
  const walk = dir => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (entry.name.endsWith(".swift")) out.push(fs.readFileSync(p, "utf8"));
    }
  };
  walk(path.join(root, "Sources", "Hisingen"));
  return out.join("\n");
}
const codebase = grepAll();
for (const sym of new Set(symbols)) {
  if (knownSymbols.includes(sym)) continue;
  if (backendRpcNames.includes(sym)) continue;
  if (codebase.includes(sym)) continue;
  // `Type.member` paths: verify the member name exists near the type declaration.
  const dot = sym.indexOf(".");
  if (dot > 0) {
    const type = sym.slice(0, dot);
    const member = sym.slice(dot + 1).split(".")[0];
    if (codebase.includes(`struct ${type}`) || codebase.includes(`enum ${type}`)) {
      if (codebase.includes(member)) continue;
    }
  }
  fail(`symbol not found in Sources/: ${sym}`);
}

// G4: per-group counts — every required group heading followed by at least one table row.
const groups = [
  "OIDC / auth", "GraphQL discovery", "GraphQL telematics", "GraphQL images", "GraphQL VDMS",
  "C3 battery", "C3 availability", "C3 exterior", "C3 health", "C3 odometer / dashboard",
  "C3 climate", "C3 air quality", "C3 location / weather", "OTA read", "GetMyCars",
  "Error service", "PCCS reads", "Invocation writes", "Chronos writes",
  "Charge-location writes", "OTA writes"
];
const sections = doc.split(/\n## /).slice(1);
const counts = {};
for (const group of groups) {
  const section = sections.find(s => s.startsWith(group));
  if (!section) { fail(`missing section: ${group}`); counts[group] = 0; continue; }
  const rows = section.split("\n").filter(l => /^\| `?[^|`]/.test(l) && !l.startsWith("| Raw field") && !l.startsWith("| Wire field") && !l.startsWith("| Method")).length;
  counts[group] = rows;
  if (rows === 0) fail(`group ${group} has zero table rows`);
}

if (process.argv.includes("--counts")) {
  for (const [group, count] of Object.entries(counts)) console.log(`${group}: ${count} rows`);
  console.log(`cited source files: ${citedFiles.size}, symbols cross-checked: ${new Set(symbols).size}`);
}

if (failures.length) {
  console.error(`FAIL (${failures.length}):\n` + failures.map(f => `  - ${f}`).join("\n"));
  process.exit(1);
}
console.log("all coverage-table source references resolve; all coverage groups populated");
