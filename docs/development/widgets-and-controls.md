# Desktop widget and Control Center controls

The `HisingenWidget` SwiftPM target is the widget extension. SwiftPM produces only its
binary; the `.appex` bundle is hand-assembled by the Makefile the same way the app
bundle is, into `Hisingen.app/Contents/PlugIns/HisingenWidget.appex`.

## What ships

- **Vehicle status widget**, `systemSmall` and `systemMedium`, on macOS 15 or later:
  battery, estimated range, charging state and the next reported departure, over the same
  flat canvas, typeface and figure-over-label grammar as the panel. The 2pt charge line is
  ink at rest and amber while the car charges.
- **Per-car configuration**: the widget's Edit sheet lists every car the app has readings
  for, backed by `VehicleSelectionIntent` (an `AppIntentConfiguration` widget intent). A
  chosen car is WidgetKit-persisted per widget instance and keeps rendering even when the
  app's active car changes. An unconfigured widget follows the active car exactly as it
  always has, so existing installs see no change.
- **Control Center controls**, macOS 26 or later: one Lock button and one Start Climate
  button, each a separate control (WidgetKit's template builder takes one template per
  control). Both are deep links, not commands.

The widget is display only. Tapping it opens the app on the existing `hisingen://` routes:
`select-car?vin=…` for the car it renders, `status` when nothing is on file. The
Control Center buttons open `lock?vin=…` and `climate/start?vin=…`, which the app treats
as any other deep link and asks for confirmation before sending. Nothing in the extension
talks to a vehicle backend.

## How data reaches the widget

`RefreshCoordinator.apply` publishes each completed refresh to
`WidgetSnapshotWriter` (`Sources/Hisingen/Services/Widget/`), which writes one small JSON
file into the App Group container `group.io.kheirallah.hisingen` and asks
`WidgetCenter` to reload all timelines. Signing out removes the file, so the widget does
not outlive the session it drew from. The publication hook disables itself outside the
real app bundle (the same gate the Notifier uses), so test runs and `swift run` builds
never touch the container.

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Bump to force older readers to refuse the file. |
| `vin`, `name` | The active car and its resolved title (label format, nickname, redaction). |
| `batteryText`, `rangeText` | Display strings, formatted by the app's own formatters, converted to the reader's distance unit. Nil means not reported, never zero. |
| `chargingKind`, `chargingText` | Stable state token plus the state's own localized words. |
| `departureText` | The next reported departure, a clock time today or "date · time" later. Nil when none is on file. |
| `fetchedAt`, `writtenAt` | Reading time (the age line is measured from it) and file write time. |
| `languageCode` | The app's selected interface language, so the widget's own strings follow it. Nil means system. |

Beside the single-car file the writer publishes the **garage** snapshot
(`vehicle-widget-garage.json`, schema 1): one entry per car the app can render — the
active car first, then every other known car that has a stored reading. It is written on
every completed refresh, so a car the reader detached, disconnected or signed out drops
out on the next refresh; the garage is the enumeration the Edit sheet lists and the
per-car widget renders from, never an independent source of fresh readings.

The widget resolves its configured VIN against the two files: a garage match renders that
car; when the garage predates the configuration but the active file still names the car,
the active file renders it; when the configured car is gone the active car stands in with
a muted note naming the car it is showing instead; with no data at all the widget draws
its placeholder ("No vehicle data yet").

Every display string is resolved app side, because the app is the only side that knows the
label format, the distance unit, the clock format and the language. The widget re-derives
exactly one value itself: the "Checked …" age line, which keeps moving after the file is
written. A missing, corrupt or future-schema file draws the placeholder ("No vehicle data
yet") and links to the panel toggle instead of a car.

The extension reloads on its own every 15 minutes so the age line stays honest, and again
on every completed refresh.

The wire shape has one definition, `Sources/HisingenIntents/VehicleWidgetSnapshot.swift`,
compiled into both binaries: the app writes the single-car and garage files through
`WidgetSnapshotWriter`, the extension reads them through `WidgetSnapshotStore` (which also
holds the age line, the one value it derives itself), and the selection resolver lives in
`Sources/HisingenWidget/VehicleConfiguration.swift`. A field or JSON key cannot be changed
on one side only. `WidgetSnapshotRoundTripTests` (Tests/HisingenWidgetTests) still writes
with the app's writer and decodes with the widget's reader, pinning the exchange end to end;
`WidgetSnapshotWriterTests` (Tests/HisingenTests/Unit) pins the app-side mapping, and
`VehicleWidgetGarageTests` (Tests/HisingenTests/Unit) pins garage enumeration, selection and
fallback; staleness thresholds are pinned widget side.

## Localization

The Makefile copies the app's `.lproj` folders into the `.appex`, so the widget resolves
the same English-key tables, and every key the widget uses (Battery, Estimated Range,
Charging, Departure, Checked %@, the age strings, No vehicle data yet, plus this work's
"Choose which car the widget shows." and "Vehicle not on file — showing %@") is in all
shipped language tables, so no key falls back to English.

## Packaging and signing

`make build` compiles the extension alongside the app. `make app` additionally lints the
extension's plist, assembles `HisingenWidget.appex` (binary, plist with version strings
synced from the app's, `.lproj` copies), and signs the extension first with
`Resources/HisingenWidget.entitlements`, then the app with
`Resources/Hisingen.entitlements`, without `--deep`: codesign's man page warns that
`--deep` applies every signing option to all nested content, which would stamp the app's
entitlements over the extension's and re-sign Sparkle unnecessarily. Sparkle ships a valid
signature of its own that the app build now preserves. `make universal` lipo's the widget
binary beside the app's.

## Widget configuration without App Intents metadata

`app-intents-metadata.md` records that a SwiftPM build cannot emit the const values
`appintentsmetadataprocessor` needs, so no `Metadata.appintents` file can ship. That
blocker is about **discovery**: Shortcuts, Siri and the Focus filter read that file to find
intents from outside the app. A widget's Edit sheet is different — WidgetKit resolves the
configuration intent **inside the extension's own process**, so the intent only needs to
exist in the extension binary, and it does not need to be discoverable by anything else.

This was settled empirically on 2026-11-22, Xcode 26.6 toolchain, macOS 26.5 SDK:

- `swift build -c release` compiles and links the extension with
  `AppIntentConfiguration` + `VehicleSelectionIntent` (a `WidgetConfigurationIntent`) with
  no metadata step: `Linking HisingenWidget`, `Build complete!`, exit 0.
- `make app IDENTITY=- NOTARIZE=never` assembles the `.appex` (binary, plist, all 15
  `.lproj` copies) and `codesign --verify --deep --strict` passes on the signed bundle.
- The same release build still has no `Metadata.appintents`; the extractor's own words
  (`Scripts/appintents-metadata-status.sh`) are unchanged: `warning: No swift const values
  found. If SWIFT_ENABLE_EMIT_CONST_VALUES = NO, App Intents metadata cannot be extracted.`
  / `Extracted no relevant App Intents symbols, skipping writing output`.

So the intent is deliberately **not** exposed to Shortcuts or Siri — the metadata gap
still stands for that, and this design never needs it. What remains verified only by
compilation is the live gallery round trip, tracked in the ledger below.

## Deliberate limits

- **No interactive buttons in the widget.** App Intents metadata emission is not available
  to a SwiftPM build (a separate work item), so interactive widget buttons cannot be
  produced here; `widgetURL` deep links are the whole interaction model instead.
- **The live colour is amber, not the reader's theme accent.** Reader-made themes live in
  the app's database, which the App Group container does not carry.
- **The car picker is gallery-only.** `VehicleSelectionIntent` resolves inside the widget's
  Edit sheet and is deliberately not surfaced in Shortcuts or Siri, which would require the
  `Metadata.appintents` a SwiftPM build cannot emit.
- **Control Center is macOS 26+.** The controls are gated with `#available(macOS 26.0, *)`
  and do not exist on earlier systems.

## Live checks still owed

Honesty ledger for what was verified against what was assumed:

1. **Widget gallery listing.** The bundle assembles, the plist lints, the app declares
   `NSSupportsWidgets`, the binary carries a real `_main` entry point, and the
   `AppIntentConfiguration` extension links cleanly at release optimization (2026-11-22).
   Still owed live: install a signed build and confirm the widget appears in the gallery
   and renders, then exercise the Edit sheet's car picker. Note observed on this machine
   (2026-11-22): `pluginkit -m` lists neither this build's appex nor the widget extension
   of the Hisingen 3.0.2 copy installed in /Applications — both are absent from that
   registry while a third-party widget installed there is listed — so the gallery round
   trip needs eyes on the machine either way. The pre-configuration widget behaves the
   same way, so nothing about this feature depends on that gap closing.
2. **Control Center listing.** `StaticControlConfiguration` with the system
   `OpenURLIntent` compiles and links against the macOS 26.5 SDK, and needs no custom
   App Intents metadata. Live check: install a signed build on macOS 26 and confirm both
   controls appear in Control Center's customization list and open the app.
3. **App Group container access.** Both processes declare the group in entitlements;
   macOS also honours the container for unsandboxed processes. Live check: run the signed
   pair and confirm the widget renders the app's snapshot bytes.
