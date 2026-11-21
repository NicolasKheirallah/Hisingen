# App Intents metadata

Hisingen ships 23 App Intents and 10 `AppShortcut` phrases. None of them is discoverable by
Shortcuts, Siri or the Focus filter in a release build, because the app bundle has no
`Metadata.appintents`. This page records what was measured on 2026-11-21, why the blocker is the
build system rather than the code, and what would unblock it.

Check the current state in one step:

```sh
sh Scripts/appintents-metadata-status.sh
```

The script reports whether a built bundle carries the metadata and, when it does not, runs the
extractor itself so its own verdict appears instead of a guess.

## What the extractor needs

`appintentsmetadataprocessor` compiles the metadata bundle from two inputs: the intent sources,
and `.swiftconstvalues` files the Swift compiler produces alongside object files. Run it against
this checkout and it says so directly:

```text
warning: No swift const values found. If SWIFT_ENABLE_EMIT_CONST_VALUES = NO, AppIntents metadata cannot be extracted.
Extracted no relevant App Intents symbols, skipping writing output
```

`SWIFT_ENABLE_EMIT_CONST_VALUES` is an Xcode build setting. Xcode turns it into a per-file
`-emit-const-values-path` on every frontend compile, and the extractor reads the resulting list.
SwiftPM has no equivalent setting, and the flag alone is not enough, as the next section shows.

## What was tried

Each step was run on this machine (Xcode 26.6, Swift 6.2, macOS 26.5 SDK).

| Attempt | Result |
| --- | --- |
| `swift build -c release` with `-Xswiftc -Xfrontend -emit-const-values-path -Xswiftc -Xfrontend <file>` | The build succeeds and writes `[]`. SwiftPM drives every compile through `-output-file-map`, so the driver plans one frontend job with `-filelist` and `-supplementary-output-file-map`; the const-values path from a build setting is not attached to the per-file supplementary outputs, and the one file the driver does write ends up empty. |
| `-Xswiftc -num-threads -Xswiftc 1` to defeat a last-writer-wins race | Same `[]`. The threading was not the cause. |
| `swiftc -c -wmo` on a single file with `-Xfrontend -const-gather-protocols-file` and `-Xfrontend -emit-const-values-path` | **Works**: the JSON lists the type, its conformance and its static members, including `@Parameter` titles. So the compiler can extract these values. The obstacle is only that SwiftPM cannot ask for it per file. |
| The same extraction over the whole module in one command, replaying SwiftPM's own recorded compile command with `-emit-module` and `-output-file-map` removed | Compiles, but writes no const values: the driver still constructs a supplementary-output-file-map for the `-filelist` job, and the standalone path is ignored. |
| Enabling the compiler's `ExtractConstantsFromMembers` feature directly | Rejected: `experimental feature 'ExtractConstantsFromMembers' cannot be enabled in production compiler`. A release toolchain does not allow it. |

The protocol list also has to use unqualified names (`AppIntent`, not `AppIntents.AppIntent`).

## What would unblock it, cheapest first

1. **A real Xcode target or build phase for the app.** Xcode sets `SWIFT_ENABLE_EMIT_CONST_VALUES`
   and runs the extractor itself; this is the supported path, and the app's intents are already
   ordinary Swift. The cost is moving the app from a hand-assembled SwiftPM bundle to an Xcode
   project or adding a small Xcode project that builds the same sources for release.
2. **A SwiftPM feature that emits per-file const values.** Watch `swift-package-manager` for a
   setting equivalent to `SWIFT_ENABLE_EMIT_CONST_VALUES`; when it lands, add the flag to
   `swift build` here, copy `Metadata.appintents` into `Contents/Resources`, and run the script
   above to confirm.
3. **A custom build step that replays every frontend command.** Possible in principle: read the
   plan from `swift build -v`, split it per primary file, and rerun each with its own const-values
   path. Rejected for now: it doubles build time, it breaks whenever SwiftPM changes its command
   shape, and a release path that silently produces no metadata is worse than one that says it
   cannot.

Until one of those lands, the widget's interactive buttons stay unshipped (they need the same
metadata), the Focus filter stays dormant, and the app's intents are reachable only through the
`hisingen://` URL scheme, which needs no metadata.
