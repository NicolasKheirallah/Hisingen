# Build

## Makefile targets

| Target | What it does |
|---|---|
| `make doctor` | Runs `Scripts/doctor.sh` — verifies the selected Xcode/CLT toolchain is internally consistent (compiler, SDK, SwiftPM all compatible) before attempting a build. |
| `make build` | (depends on `doctor`) `swift build -c release $(SWIFT_FLAGS)`. |
| `make universal` | (depends on `doctor`) Builds arm64 and x86_64 release binaries into **separate scratch build directories** (`.build-arm64`, `.build-x86_64` — avoiding SwiftPM artifact reuse across architectures), then `lipo -create`s them into one universal binary and verifies both architectures are present. |
| `make app` | (depends on `build`, skippable via `SKIP_BUILD=1`) Lints `Info.plist`, assembles `releases/Hisingen.app`, injects updater configuration, embeds and signs `Sparkle.framework`, adds the framework runtime path, then signs the app. Ad-hoc (`-s -`) by default; hardened-runtime signing (`--options runtime --timestamp`) when `IDENTITY` contains "Developer ID". |
| `make app-universal` | (depends on `universal`) Equivalent to `make app SKIP_BUILD=1 IDENTITY="$(IDENTITY)"` using the universal binary. |
| `make dmg` | Requires `$(APP)` to already exist (fails with a clear message otherwise). Stages the app plus an `Applications` symlink and builds a UDZO disk image via `hdiutil create`. Deliberately **not** a dependency of `app` — re-running `app` after notarization would re-sign the bundle and void the notarization staple, so `dmg` must be invoked as a separate, later step. |
| `make run` | `swift run` — unbundled dev run, no launch-at-login, no stable signing identity. |
| `make test` | (depends on `doctor`) Runs `Scripts/test.sh`. |
| `make clean` | Removes `.build`, `.build-arm64`, `.build-x86_64`, local app/DMG/zip outputs in `releases/`, staging files, `SHA256SUMS`, and `notarize-app.zip`. |
| `make release VERSION=x.y.z` | Requires a matching `CHANGELOG.md` entry, validates the version format and a clean working tree, bumps `CFBundleShortVersionString` (via `PlistBuddy`) and increments `CFBundleVersion`, commits, tags `vX.Y.Z`, and pushes both — which triggers `.github/workflows/release.yml`. See [releases.md](releases.md). |

Default `IDENTITY` is `-` (ad-hoc). CI's release job passes a real `"Developer ID Application: ..."` identity resolved dynamically from an imported certificate.

## Scripts

**`Scripts/doctor.sh`** (POSIX `sh`, `set -eu`) — resolves the active developer directory (`$DEVELOPER_DIR` env override, else `xcode-select -p`), fails clearly if none is selected. Prints `swiftc --version` and the SDK path, then runs `swift package dump-package` in an isolated module-cache directory purely as a smoke test that the compiler/SDK/SwiftPM combination is mutually compatible — a common failure mode after an Xcode upgrade or a CLT/Xcode toolchain mismatch.

**`Scripts/test.sh`** (POSIX `sh`, `set -eu`) — detects whether the selected developer tools are the *standalone* Command Line Tools (as opposed to full Xcode). If so, it adds an extra `-F` framework search path (`$CLT/Library/Developer/Frameworks`) before invoking `swift test`, because standalone CLT ships the Swift Testing framework outside the SDK's normal search path — this mirrors equivalent logic duplicated in `Package.swift`'s `usesStandaloneCommandLineTools`/`testSwiftSettings`/`testLinkerSettings`. Forwards any extra arguments transparently (`--filter`, etc.).

**`Scripts/select-xcode.sh`** (POSIX `sh`, `set -eu`) — selects a valid full
Xcode developer directory from an explicit override, the active `xcode-select`
path, or an installed `/Applications/Xcode*.app`. In GitHub Actions it persists
the selection through `GITHUB_ENV`; CI, CodeQL, live integration, and release
jobs all use this one implementation.

**`Scripts/configure-updater.sh`** — injects the HTTPS Sparkle feed URL and
Ed25519 public key into the bundle plist. Distributable builds require the key,
and it must decode to exactly 32 bytes.

**`Scripts/verify-updater.mjs`** — checks updater configuration, framework
packaging and load paths, release-pipeline controls, release-note extraction,
and generated appcast signature structure. Its self-tests include negative
cases for malformed keys, missing notes, and incomplete signatures.

**`Scripts/check-localization.py`** — a standalone Python QA script (not wired into `make`/CI as of this writing) that scans `Sources/Hisingen/Resources/*.lproj/Localizable.strings` for duplicate keys within a file and reports translation coverage gaps relative to the English base locale. It reports missing keys rather than failing on them, since `Support/L10n.swift` already falls back to English for anything missing from the active locale — an incomplete translation degrades gracefully, it isn't a build-breaking bug.

## Requirements

macOS 15 Sequoia or later; Xcode 16+ or compatible Command Line Tools with Swift 6.0+. `Package.swift` declares `swift-tools-version:6.0`, `platforms: [.macOS(.v15)]`, and an exact Sparkle `2.9.6` package dependency.

## Strict concurrency

The package builds in the Swift 6 language mode with complete concurrency checking, declared in `Package.swift` (`.enableUpcomingFeature("StrictConcurrency")` on every target). No `SWIFT_FLAGS` or `-Xswiftc` flags are needed — `swift build`, `make build`, Xcode, and IDE indexing are all checked identically. See [architecture/concurrency.md](../architecture/concurrency.md).

## Remote-command dispatch

There is no build flag for this any more. `HISINGEN_EXPERIMENTAL_REMOTE` was removed in [ADR-0009](../adr/0009-remote-commands-compiled-into-all-builds.md); Polestar's remote-command path is compiled into every build, including releases. It stays inert until the matching capability is enabled in Settings, and non-routine commands still require Touch ID — see [security/threat-model.md](../security/threat-model.md#remote-control-surface).

## Verifying a local build

```bash
codesign --verify --deep --strict releases/Hisingen.app   # signature integrity
lipo -info releases/Hisingen.app/Contents/MacOS/Hisingen   # architecture(s) present
plutil -lint releases/Hisingen.app/Contents/Info.plist
test -d releases/Hisingen.app/Contents/Frameworks/Sparkle.framework
otool -L releases/Hisingen.app/Contents/MacOS/Hisingen
otool -l releases/Hisingen.app/Contents/MacOS/Hisingen
```

CI's bundle-validation step (see [ci.md](ci.md)) runs equivalent checks automatically, including the Sparkle load path and metadata, plus asserting `LSUIElement == true` (the app must remain a background/accessory app with no Dock icon).
