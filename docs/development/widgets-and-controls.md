# Desktop widget and Control Center controls

The `HisingenWidget` SwiftPM target is the widget extension. SwiftPM produces only its
binary; the `.appex` bundle is hand-assembled by the Makefile the same way the app
bundle is, into `Hisingen.app/Contents/PlugIns/HisingenWidget.appex`.

## What ships

- **Vehicle status widget**, `systemSmall` and `systemMedium`, on macOS 15 or later:
  battery, estimated range, charging state and the next reported departure, over the same
  flat canvas, typeface and figure-over-label grammar as the panel. The 2pt charge line is
  ink at rest and amber while the car charges.
- **Control Center controls**, macOS 26 or later: one Lock button and one Start Climate
  button, each a separate control (WidgetKit's template builder takes one template per
  control). Both are deep links, not commands.

The widget is display only. Tapping it opens the app on the existing `hisingen://` routes:
`select-car?vin=…` when a snapshot names a car, `status` when nothing is on file. The
Control Center buttons open `lock?vin=…` and `climate/start?vin=…`, which the app treats
as any other deep link and asks for confirmation before sending. Nothing in the extension
talks to a vehicle backend, and no App Intents metadata is required for this design.

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

Every display string is resolved app side, because the app is the only side that knows the
label format, the distance unit, the clock format and the language. The widget re-derives
exactly one value itself: the "Checked …" age line, which keeps moving after the file is
written. A missing, corrupt or future-schema file draws the placeholder ("No vehicle data
yet") and links to the panel toggle instead of a car.

The extension reloads on its own every 15 minutes so the age line stays honest, and again
on every completed refresh.

The two sides of the wire shape live in separate targets with no shared module:
`Sources/Hisingen/Services/Widget/VehicleWidgetSnapshot.swift` writes,
`Sources/HisingenWidget/VehicleWidgetSnapshot.swift` reads. `WidgetSnapshotRoundTripTests`
(Tests/HisingenWidgetTests) imports both binaries and pins the exchange end to end;
`WidgetSnapshotWriterTests` (Tests/HisingenTests/Unit) pins the app-side mapping,
staleness thresholds are pinned widget side.

## Localization

The Makefile copies the app's `.lproj` folders into the `.appex`, so the widget resolves
the same English-key tables. The keys the widget needs (Battery, Estimated Range,
Charging, Departure, Checked %@, the age strings, No vehicle data yet) already exist in
every shipped language. The keys this work adds travel in
`l10n-drafts/widget-controls.strings` until they are merged into the tables; until then
the widget falls back to the English keys, exactly as `L10n` does for an untranslated key.

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

## Deliberate limits

- **No interactive buttons in the widget.** App Intents metadata emission is not available
  to a SwiftPM build (a separate work item), so interactive widget buttons cannot be
  produced here; `widgetURL` deep links are the whole interaction model instead.
- **The live colour is amber, not the reader's theme accent.** Reader-made themes live in
  the app's database, which the App Group container does not carry.
- **One car.** The snapshot is the active car's; there is no per-car widget yet.
- **Control Center is macOS 26+.** The controls are gated with `#available(macOS 26.0, *)`
  and do not exist on earlier systems.

## Live checks still owed

Honesty ledger for what was verified against what was assumed:

1. **Widget gallery listing.** The bundle assembles, the plist lints, the app declares
   `NSSupportsWidgets`, and the binary carries a real `_main` entry point. Live check:
   install a signed build and confirm the widget appears in the gallery and renders.
2. **Control Center listing.** `StaticControlConfiguration` with the system
   `OpenURLIntent` compiles and links against the macOS 26.5 SDK, and needs no custom
   App Intents metadata. Live check: install a signed build on macOS 26 and confirm both
   controls appear in Control Center's customization list and open the app.
3. **App Group container access.** Both processes declare the group in entitlements;
   macOS also honours the container for unsandboxed processes. Live check: run the signed
   pair and confirm the widget renders the app's snapshot bytes.
