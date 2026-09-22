#!/usr/bin/env node
// Structural verifier for scope opps-20260921 (product-audit opportunities). Each check
// asserts the artifact contains the committed change; behavior is proven by the unit tests
// the full suite (G14) executes. Usage: node Scripts/verify-opps-20260921.mjs G<n>
// Prints OPPS_CHECK_PASSED: G<n> and exits 0 when that gate's assertions all hold.
import fs from "node:fs";
import { execSync } from "node:child_process";
import process from "node:process";

const read = (p) => fs.readFileSync(p, "utf8");
const has = (text, needle) => text.includes(needle);
const count = (text, needle) => text.split(needle).length - 1;
const fail = (msgs) => {
  for (const m of msgs) console.error(`  FAIL: ${m}`);
  process.exit(1);
};

const gate = process.argv[2] ?? "";
const src = "Sources/Hisingen";
const tst = "Tests/HisingenTests";

if (gate === "G1") {
  const kc = read(`${src}/Services/Persistence/Keychain.swift`);
  const vse = read(`${src}/Services/API/VehicleServiceError.swift`);
  const test = read(`${tst}/Unit/KeychainMigrationTests.swift`);
  const msgs = [];
  if (!has(kc, "case interactionRequired")) msgs.push("KeychainError.interactionRequired missing");
  if (count(kc, "errSecInteractionRequired") < 5) msgs.push("errSecInteractionRequired mapping missing from read/save/delete");
  if (!has(vse, "case keychainConsentRequired")) msgs.push("VehicleServiceError.keychainConsentRequired missing");
  if (!has(vse, "keychain.isInteractionRequired ? .keychainConsentRequired : .secureStorage")) msgs.push("map() does not classify consent");
  if (!has(test, "consentPendingReadThrowsInteractionRequiredWithoutLegacyFallback")) msgs.push("consent read test missing");
  if (!has(test, "consentRequiredMapsToItsOwnParkedServiceError")) msgs.push("consent mapping test missing");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G1");
} else if (gate === "G2") {
  const rc = read(`${src}/Services/Refresh/RefreshCoordinator.swift`);
  const sm = read(`${src}/Services/Security/SessionManager.swift`);
  const ps = read(`${src}/Services/Persistence/PreferencesStore.swift`);
  const startBlock = rc.split("func start(preferredVIN")[1]?.split("func credentialsChanged")[0] ?? "";
  const msgs = [];
  if (!has(startBlock, "resolveAccountEmailInTheBackground()")) msgs.push("start() does not defer email resolution");
  if (has(startBlock, "accountEmail = preferences.email")) msgs.push("start() still reads preferences.email synchronously");
  if (!has(rc, "Task.detached(priority: .utility)")) msgs.push("detached email resolution missing");
  if (!has(sm, "@Sendable () throws -> String?")) msgs.push("SessionManager readPassword not @Sendable");
  if (!has(sm, "Task.detached(priority: .userInitiated)")) msgs.push("stored password read not detached");
  if (!has(ps, "catch KeychainError.interactionRequired")) msgs.push("email getter does not special-case consent");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G2");
} else if (gate === "G3") {
  const merge = read(`${src}/Domain/VehicleState+Merging.swift`);
  const test = read(`${tst}/Unit/VehicleRetentionHorizonTests.swift`);
  const msgs = [];
  if (!has(merge, "static let retainedDataHorizon")) msgs.push("retainedDataHorizon missing");
  if (!has(merge, "previousRetainedDataIsRecent")) msgs.push("retained carry not horizon-bounded");
  if (!has(merge, "previousReadingIsRecent(.connectivity)")) msgs.push("connectivity carry not horizon-bounded");
  if (!has(merge, "previousReadingIsRecent(.software)")) msgs.push("software carry not horizon-bounded");
  if (!has(test, "agedSoftwareAndConnectivityDropInsteadOfPinningTheBanner")) msgs.push("expiry test missing");
  if (!has(test, "recentReadingsStillCarryAndMarkAsBefore")) msgs.push("recent-carry control test missing");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G3");
} else if (gate === "G4") {
  const inst = read(`${src}/UI/Vehicle/AwardVehicleInstrument.swift`);
  const derived = read(`${src}/Domain/VehicleState+Derived.swift`);
  const test = read(`${tst}/Unit/VehicleVerdictTests.swift`);
  const msgs = [];
  if (!has(derived, "var activeVerdict: String?")) msgs.push("activeVerdict missing in domain");
  if (!has(derived, "hasOldData()")) msgs.push("verdict does not guard stale data");
  if (!has(inst, "state.activeVerdict")) msgs.push("instrument does not render the verdict");
  if (!has(test, "chargingTakesPrecedenceOverClimate")) msgs.push("verdict precedence test missing");
  if (!has(test, "connectedButIdleCarHasNoVerdict")) msgs.push("idle-fallback test missing");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G4");
} else if (gate === "G5") {
  const res = `${src}/Resources`;
  const msgs = [];
  for (const locale of ["da","de","en","es","fi","fr","it","ko","nb","nl","nn","no","pl","pt","sv","zh"]) {
    if (!fs.existsSync(`${res}/${locale}.lproj/AppShortcuts.strings`)) msgs.push(`AppShortcuts.strings missing for ${locale}`);
    const strings = read(`${res}/${locale}.lproj/Localizable.strings`);
    for (const key of ["Verify now", "Vehicle Controls", "Climate unavailable", "Get Vehicle Battery"]) {
      if (!strings.includes(`"${key}" = `)) msgs.push(`key "${key}" missing in ${locale}`);
    }
  }
  try {
    const out = execSync("node Scripts/audit-l10n-literals.mjs", { encoding: "utf8" });
    if (!has(out, "AUDIT_L10N_PASSED")) msgs.push("literal auditor did not pass");
  } catch (e) {
    msgs.push(`literal auditor failed: ${String(e.stdout ?? e).slice(0, 400)}`);
  }
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G5");
} else if (gate === "G6") {
  const validator = read(`${src}/Domain/FuelFillUpValidation.swift`);
  const fuel = read(`${src}/UI/History/HistoryDashboardView+Fuel.swift`);
  const test = read(`${tst}/Unit/FuelFillUpValidationTests.swift`);
  const msgs = [];
  if (!has(validator, "static func validate(volumeText:")) msgs.push("pure validator missing");
  if (!has(fuel, "validation.isValid")) msgs.push("sheet does not consume the validator");
  if (!has(fuel, ".disabled(!validation.isValid)")) msgs.push("Save not disabled when invalid");
  if (!has(fuel, "validation.reason(for:")) msgs.push("per-field reasons not rendered");
  if (!has(test, "volumeMustBeGreaterThanZero")) msgs.push("validator tests missing");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G6");
} else if (gate === "G7") {
  const chip = read(`${src}/UI/Components/CommandReceiptChip.swift`);
  const vehicle = read(`${src}/UI/Vehicle/VehicleTabView.swift`);
  const controls = read(`${src}/UI/Controls/ControlsTabView.swift`);
  const stack = read(`${src}/UI/Shell/TabCardStack.swift`);
  const msgs = [];
  if (!has(chip, "var onVerify: ((UUID) -> Void)? = nil")) msgs.push("chip onVerify missing");
  if (!has(chip, "if case .acknowledged = receipt.status, let onVerify")) msgs.push("verify shown for other statuses");
  if (!has(chip, '"Verify now"')) msgs.push("verify button missing");
  if (!has(vehicle, "onVerifyReceipt: ((UUID) -> Void)? = nil")) msgs.push("Vehicle tab verify param missing");
  if (!has(controls, "onVerify: { _ in onRefresh() }")) msgs.push("controls verify not wired");
  if (!has(stack, "onVerify: { _ in onRefresh() }")) msgs.push("card stack verify not wired");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G7");
} else if (gate === "G8") {
  const catalog = read(`${src}/Domain/TabItemCatalog.swift`);
  const controls = read(`${src}/UI/Controls/ControlsTabView.swift`);
  const msgs = [];
  // The Controls planner card got its own tab id (controlsChargingPlanner) when tab ids
  // were namespaced per tab; the vehicle planner keeps vehicleChargingPlanner.
  if (!has(catalog, ".controlsCharging, .controlsChargingPlanner, .controlsAccess")) msgs.push("planner not in default Controls order");
  if (!has(controls, "id: TabItemID.controlsChargingPlanner.rawValue")) msgs.push("planner CardEntry missing on Controls");
  if (!has(controls, "features.contains(.smartChargingPlanner) && state.powertrain.hasElectricRange")) msgs.push("planner gating missing");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G8");
} else if (gate === "G9") {
  const db = read(`${src}/Services/Persistence/VehicleDatabase.swift`);
  const card = read(`${src}/UI/Settings/SettingsDatabaseCard.swift`);
  const msgs = [];
  if (!has(db, "static let sessionRetentionDays = 730")) msgs.push("session horizon constant missing");
  if (!has(db, "chargingSessionsOlderThanDays: Int = VehicleDatabase.sessionRetentionDays")) msgs.push("prune default not sourced from the constant");
  if (!has(card, "Keeps samples %d days. Charging and health summaries are kept %d days.")) msgs.push("caption missing real numbers");
  if (!has(card, "VehicleDatabase.sessionRetentionDays")) msgs.push("caption not bound to the constant");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G9");
} else if (gate === "G10") {
  const map = read(`${src}/UI/Controls/AwardControlMap.swift`);
  const msgs = [];
  if (has(map, "0.62")) msgs.push("constant fake gauge fill still present");
  if (has(map, "chargeProgress")) msgs.push("target-as-progress member still present");
  if (!has(map, "state.isCharging, let target = state.energy.targetPercentage")) msgs.push("charge rail not bound to real progress");
  if (!has(map, "a target is a setting, not a level")) msgs.push("design reason not recorded");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G10");
} else if (gate === "G11") {
  const overview = read(`${src}/UI/History/HistoryDashboardView+AwardOverview.swift`);
  const msgs = [];
  if (!has(overview, "struct AwardTripBars")) msgs.push("trip bars component missing");
  if (!has(overview, "@FocusState")) msgs.push("keyboard focus missing");
  if (!has(overview, "selectedDetail")) msgs.push("selection detail missing");
  if (!has(overview, ".accessibilityAddTraits(isSelected ? .isSelected : [])")) msgs.push("selected trait missing");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G11");
} else if (gate === "G12") {
  const freshness = read(`${src}/Domain/SnapshotFreshness.swift`);
  const provider = read(`${src}/Services/Refresh/PolestarAugmentedProvider.swift`);
  const merging = read(`${src}/Domain/SnapshotMerging.swift`);
  const derived = read(`${src}/Domain/VehicleState+Derived.swift`);
  const test = read(`${tst}/Unit/VehicleRetentionHorizonTests.swift`);
  const msgs = [];
  if (!has(freshness, "var servedByFallback: Bool? = nil")) msgs.push("freshness marker missing");
  if (!has(merging, "servedByFallback: servedByFallback")) msgs.push("merge drops the marker");
  if (count(provider, "servedByFallback = true") < 2) msgs.push("provider does not mark both fallback paths");
  if (!has(derived, "(via Polestar ID)")) msgs.push("age line does not surface the source");
  if (!has(test, "fallbackMarkerSurvivesTheMergeAndLabelsTheAgeLine")) msgs.push("marker test missing");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G12");
} else if (gate === "G19") {
  const changelog = read("CHANGELOG.md");
  const msgs = [];
  if (!has(changelog, "## [2.0.5] - 2026-09-21")) msgs.push("[2.0.5] heading missing");
  const block = changelog.split("## [2.0.5]")[1]?.split("\n## [")[0] ?? "";
  if (!has(block, "Keychain")) msgs.push("keychain entry missing from 2.0.5");
  if (!has(block, "last-known")) msgs.push("banner entry missing from 2.0.5");
  if (msgs.length) fail(msgs);
  console.log("OPPS_CHECK_PASSED: G19");
} else {
  console.error(`unknown gate: ${gate}`);
  process.exit(1);
}
