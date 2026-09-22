#!/usr/bin/env node

import { readFileSync, readdirSync, statSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");

const surfaces = [
  ["Vehicle", "docs/design/award-concept/01-vehicle.png", "Sources/Hisingen/UI/Vehicle/VehicleTabView.swift", "struct VehicleTabView"],
  ["Info", "docs/design/award-concept/02-info.png", "Sources/Hisingen/UI/Info/InfoTabView.swift", "struct InfoTabView"],
  ["History", "docs/design/award-concept/03-history.png", "Sources/Hisingen/UI/History/HistoryDashboardView.swift", "struct HistoryDashboardView"],
  ["Controls", "docs/design/award-concept/04-controls.png", "Sources/Hisingen/UI/Controls/ControlsTabView.swift", "struct ControlsTabView"],
  ["Settings", "docs/design/award-concept/05-settings.png", "Sources/Hisingen/UI/Settings/SettingsView.swift", "struct SettingsView"],
  ["Sign in", "docs/design/award-concept/06-sign-in.png", "Sources/Hisingen/UI/Shell/WelcomeSignInView.swift", "struct WelcomeSignInView"],
  ["Setup", "docs/design/award-concept/07-setup.png", "Sources/Hisingen/UI/Shell/SetupPassView.swift", "struct SetupPassView"],
  ["State atlas", "docs/design/award-concept/08-state-atlas.png", "Sources/Hisingen/UI/Components/HisingenEmptyState.swift", "struct HisingenEmptyState"],
];

const failures = [];

const productionFocals = [
  ["Vehicle instrument", "Sources/Hisingen/UI/Vehicle/AwardVehicleInstrument.swift", "struct AwardVehicleInstrument"],
  ["Info passport", "Sources/Hisingen/UI/Info/InfoTabView+AwardPassport.swift", "awardVehiclePassport"],
  ["History instrument", "Sources/Hisingen/UI/History/HistoryDashboardView+AwardOverview.swift", "awardHistoryOverview"],
  ["Controls map", "Sources/Hisingen/UI/Controls/AwardControlMap.swift", "struct AwardControlMap"],
];

const swiftFiles = (directory) => readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
  const path = resolve(directory, entry.name);
  if (entry.isDirectory()) return swiftFiles(path);
  return entry.isFile() && entry.name.endsWith(".swift") ? [path] : [];
});

for (const [name, imagePath, sourcePath, sourceMarker] of surfaces) {
  const absoluteImage = resolve(root, imagePath);
  const absoluteSource = resolve(root, sourcePath);
  try {
    if (statSync(absoluteImage).size < 10_000) {
      failures.push(`${name}: render is unexpectedly small (${imagePath})`);
    }
  } catch {
    failures.push(`${name}: render is missing (${imagePath})`);
  }

  try {
    const source = readFileSync(absoluteSource, "utf8");
    if (!source.includes(sourceMarker)) {
      failures.push(`${name}: source marker is missing (${sourceMarker})`);
    }
  } catch {
    failures.push(`${name}: source is missing (${sourcePath})`);
  }
}

for (const [name, sourcePath, sourceMarker] of productionFocals) {
  try {
    const source = readFileSync(resolve(root, sourcePath), "utf8");
    if (!source.includes(sourceMarker)) failures.push(`${name}: production focal marker is missing`);
  } catch {
    failures.push(`${name}: production focal source is missing (${sourcePath})`);
  }
}

for (const sourcePath of swiftFiles(resolve(root, "Sources/Hisingen/UI"))) {
  if (readFileSync(sourcePath, "utf8").includes('systemName: "sparkles"')
      || readFileSync(sourcePath, "utf8").includes('symbol: "sparkles"')) {
    failures.push(`generic sparkle icon remains in ${sourcePath.slice(root.length + 1)}`);
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}

console.log(`PAGE_COVERAGE_VERIFIED: ${surfaces.length} primary surfaces and ${productionFocals.length} production focal compositions have evidence`);
