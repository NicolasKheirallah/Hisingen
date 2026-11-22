# App Intents metadata

Hisingen ships 24 App Intents, 10 `AppShortcut` groups and a Focus filter. The build produces
`Metadata.appintents`, so Shortcuts, Siri and the Focus filter can discover all of them.

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
   The command is cached per dependency graph, so a clean checkout pays for it once.
2. Replay it in the same batch shape SwiftPM uses — `-filelist` plus `-output-filelist`, one object
   per source — with `-const-gather-protocols-file` and `-emit-const-values-path` added, writing the
   objects into a throwaway directory. `-O` becomes `-Onone`: optimisation is irrelevant to
   compile-time constants and roughly halves the run.
3. Run `appintentsmetadataprocessor` over those values and write `Metadata.appintents`.

`make app` runs this step and installs the bundle at `Contents/Resources/Metadata.appintents`.
`SKIP_APPINTENTS=1 make app` leaves it out for a quick bundle-only iteration; the app still runs,
and Shortcuts then lists nothing.

`Scripts/validate-release.sh --artifacts` fails a release that carries no populated metadata, so a
missing bundle cannot ship silently. `REQUIRE_APPINTENTS=false` opts out for a deliberate build.

## Facts worth keeping

- The protocol list must use **unqualified** names (`AppIntent`, not `AppIntents.AppIntent`), and it
  is JSON (`["AppIntent","AppShortcutsProvider"]`). A newline list is rejected as malformed.
- Constant extraction happens for `-c` compiles. `-emit-ir` produces none.
- The extractor matches source paths exactly; it wants the same relative paths the compiler was
  given, not absolute ones.
- `-O` versus `-Onone` does not change the extracted values, only the time it takes.

## What this unblocks

- **Interactive widget buttons** and **real Control Center actions** still need the widget target's
  own `Metadata.appintents`, built the same way from that module.
- The Focus filter and the `AppShortcut` phrases are discoverable now that the app bundle carries
  metadata.
