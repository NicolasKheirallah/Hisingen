import fs from "node:fs";

const read = (path) => fs.readFileSync(path, "utf8");
const settings = read("Sources/Hisingen/UI/SettingsView.swift");
const databaseCard = read("Sources/Hisingen/UI/SettingsDatabaseCard.swift");
const preferences = read("Sources/Hisingen/Services/Persistence/PreferencesStore.swift");
const account = read("Sources/Hisingen/UI/AccountCredentialsForm.swift");
const feature = read("Sources/Hisingen/Domain/AppFeature.swift");

const checks = [
  [preferences.includes("set.formUnion([.vehicleLocation, .vehicleWeather, .ownerGreeting])") === false,
   "saved feature opt-outs are not force-enabled"],
  [settings.includes("preferences.customPanelSizeEnabled = false"),
   "preset selection persists custom-size disablement"],
  [settings.includes("SettingsNavigationBar") && settings.includes("LazyVStack"),
   "section navigation, search, and lazy rendering are present"],
  [settings.includes("AppFeature.safeBulkEnableCases") && feature.includes("safeBulkEnableCases"),
   "safe bulk enable excludes remote controls"],
  [databaseCard.includes(".task {") && databaseCard.includes("await loadStats()"),
   "database state and statistics hydrate on appearance"],
  [databaseCard.includes("try await Task.detached") && databaseCard.includes("vacuumOrThrow"),
   "database maintenance is awaited and error-reporting"],
  [databaseCard.includes("confirmationDialog") && databaseCard.includes("wipeAllOrThrow"),
   "destructive data operations are confirmed"],
  [databaseCard.includes("clearStoredLocationsOrThrow") && settings.includes("persistLocationHistory: $persistLocationHistory"),
   "location-history clearing is awaited and reflected in the privacy dashboard"],
  [preferences.includes('"garage_vehicle_order_v1",\n            "privacy_redaction_enabled"') === false,
   "settings transfer does not export VIN-bearing garage order"],
  [settings.includes("notifyAllPreferenceSubsystems()") && settings.includes("onSettingsChanged(.updater)"),
   "settings import and reset notify every affected subsystem"],
  [databaseCard.includes("Export All History (JSON)")
      && !databaseCard.slice(
        databaseCard.indexOf("Export All History (JSON)"),
        databaseCard.indexOf("Export Diagnostic Logs")
      ).includes(".disabled(state == nil)"),
   "history export is available independently of an active vehicle"],
  [preferences.includes("clearLegacyVehicleCaches") && databaseCard.includes("preferences.clearLegacyVehicleCaches"),
   "destructive clears remove legacy UserDefaults vehicle caches"],
  [settings.includes("Require device-owner authentication") && !settings.includes("Require Touch ID"),
   "authentication wording matches device-owner policy"],
  [account.includes(".onDisappear") && account.includes("accountDraft.volvoClientSecret = \"\""),
   "plaintext account drafts are cleared"],
  [!account.includes("asyncAfter(deadline: .now() + 3)"),
   "Volvo sign-in has no fixed fake progress timer"],
  [!settings.match(/\.task\s*\{\s*\}/s),
   "Settings has no empty task modifier"],
  [settings.includes(".accessibilityLabel(L10n.text(title))"),
   "reusable settings controls expose accessibility labels"],
];

const failures = checks.filter(([passed]) => !passed).map(([, label]) => label);
if (failures.length) {
  console.error("settings overhaul verification failed:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`settings overhaul verification passed (${checks.length} guardrails)`);
