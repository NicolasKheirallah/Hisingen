# App Intents metadata

Hisingen ships 33 App Intents, 10 `AppShortcut` groups and a Focus filter in the app, plus
the seven widget-facing intents in the shared `HisingenIntents` target. The build produces
`Metadata.appintents` for the app and a second bundle inside `HisingenWidget.appex`, so Shortcuts,
Siri, the Focus filter and interactive widget buttons can discover what they run.

Check a built bundle in one step:

```sh
sh Scripts/appintents-metadata-status.sh releases/Hisingen.app
```

## Why a build step exists

`appintentsmetadataprocessor` reads two inputs: the intent sources, and constant values the Swift
compiler extracts from the types that conform to `AppIntent` and friends. Without those values the
processor reports `No swift const values found` and writes nothing.

Xcode asks for them through the `SWIFT_ENABLE_EMIT_CONST_VALUES` build setting, which becomes a
`-emit-const-values-path` on each frontend compile. SwiftPM has no equivalent setting, so
`Scripts/generate-appintents-metadata.sh` provides one:

1. Read the module's own compile command from SwiftPM's verbose output (`swift build -c release -v`).
   The command is cached per module and dependency graph, so a clean checkout pays for it once.
2. Replay it in the same batch shape SwiftPM uses — `-filelist` plus `-output-filelist`, one object
   per source — with `-const-gather-protocols-file` and `-emit-const-values-path` added, writing the
   objects into a throwaway directory. `-O` becomes `-Onone`: optimisation is irrelevant to
   compile-time constants and roughly halves the run.
3. Run `appintentsmetadataprocessor` over those values and write `Metadata.appintents`.

The script takes `--module` and `--source-directory`, so the same mechanism covers the app, the
shared intent module and the widget extension.

`make app` runs this step and installs the app bundle at `Contents/Resources/Metadata.appintents`.
For the extension, `Scripts/generate-widget-appintents-metadata.sh` builds
`HisingenIntents.appintents`, then asks the processor to fold it into the widget module's bundle
through `--static-metadata-file-list`; the result lands at
`HisingenWidget.appex/Contents/Resources/Metadata.appintents`. The shared target is a static SwiftPM
dependency, which is why it belongs in the static list: a normal dependency list leaves its actions
out. `SKIP_APPINTENTS=1 make app` leaves both bundles out for a quick bundle-only iteration; the app
still runs, and Shortcuts then lists nothing.

`Scripts/validate-release.sh --artifacts` fails a release that carries no populated metadata in
either the app or the extension, so a missing bundle cannot ship silently.
`REQUIRE_APPINTENTS=false` opts out for a deliberate build.

## Facts worth keeping

- The protocol list must use **unqualified** names (`AppIntent`, not `AppIntents.AppIntent`), and it
  is JSON (`["AppIntent","AppShortcutsProvider"]`). A newline list is rejected as malformed.
- Constant extraction happens for `-c` compiles. `-emit-ir` produces none.
- The extractor matches source paths exactly; it wants the same relative paths the compiler was
  given, not absolute ones.
- `-O` versus `-Onone` does not change the extracted values, only the time it takes.
- Intent metadata records a **module-qualified** type name. The extension's bundle must keep the
  shared types qualified as `HisingenIntents.WidgetLockVehicleIntent`; copying the shared bundle
  under the widget's module name would name a type that does not exist in the binary.
- `--metadata-file-list` is for dynamic dependencies; `--static-metadata-file-list` is for static
  ones. SwiftPM target dependencies are static.

## What this unblocks

- **Interactive widget buttons** have the extension-side metadata they need: the vehicle
  status widget's lock, unlock, start-climate and refresh buttons name the shared intents from
  `HisingenWidget.appex`, and each runs with `openAppWhenRun`, so the app performs it through the
  registered handler and its normal capability gates.
- **Real Control Center actions** use the same intents: Unlock, Honk and Flash, Charge Now and
  Start Cabin Pre-Cleaning run with `openAppWhenRun`, while Lock and Start Climate keep their
  URL launchers.
- The Focus filter and the `AppShortcut` phrases are discoverable from the app bundle.
