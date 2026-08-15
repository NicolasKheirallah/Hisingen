# Build

## Makefile targets

| Target | What it does |
|---|---|
| `make doctor` | Runs `Scripts/doctor.sh` — verifies the selected Xcode/CLT toolchain is internally consistent (compiler, SDK, SwiftPM all compatible) before attempting a build. |
| `make build` | (depends on `doctor`) `swift build -c release $(SWIFT_FLAGS)`. |
| `make universal` | (depends on `doctor`) Builds arm64 and x86_64 release binaries into **separate scratch build directories** (`.build-arm64`, `.build-x86_64` — avoiding SwiftPM artifact reuse across architectures), then `lipo -create`s them into one universal binary and verifies both architectures are present. |
| `make app` | (depends on `build`, skippable via `SKIP_BUILD=1`) Lints `Info.plist` (`plutil -lint`), assembles the `Hisingen.app` bundle (`Contents/MacOS`, `Contents/Resources`, icon, both a `Hisingen_Hisingen.bundle` SPM resource bundle and a flat resource copy), then code-signs. Ad-hoc (`-s -`) by default with a warning about repeated Keychain/Accessibility prompts on every rebuild; hardened-runtime signing (`--options runtime --timestamp`) when `IDENTITY` contains "Developer ID". |
| `make app-universal` | (depends on `universal`) Equivalent to `make app SKIP_BUILD=1 IDENTITY="$(IDENTITY)"` using the universal binary. |
| `make dmg` | Requires `$(APP)` to already exist (fails with a clear message otherwise). Stages the app plus an `Applications` symlink and builds a UDZO disk image via `hdiutil create`. Deliberately **not** a dependency of `app` — re-running `app` after notarization would re-sign the bundle and void the notarization staple, so `dmg` must be invoked as a separate, later step. |
| `make run` | `swift run` — unbundled dev run, no launch-at-login, no stable signing identity. |
| `make test` | (depends on `doctor`) Runs `Scripts/test.sh`. |
| `make clean` | Removes `.build`, `.build-arm64`, `.build-x86_64`, the app bundle, DMG, zip, `dmg-staging/`, `SHA256SUMS`, `notarize-app.zip`. |
| `make release VERSION=x.y.z` | Validates the version format and a clean working tree, bumps `CFBundleShortVersionString` (via `PlistBuddy`) and increments `CFBundleVersion`, commits (`Release vX.Y.Z`), tags `vX.Y.Z`, and pushes both — which is what triggers `.github/workflows/release.yml`. See [releases.md](releases.md). |

Default `IDENTITY` is `-` (ad-hoc). CI's release job passes a real `"Developer ID Application: ..."` identity resolved dynamically from an imported certificate.

## Scripts

**`Scripts/doctor.sh`** (POSIX `sh`, `set -eu`) — resolves the active developer directory (`$DEVELOPER_DIR` env override, else `xcode-select -p`), fails clearly if none is selected. Prints `swiftc --version` and the SDK path, then runs `swift package dump-package` in an isolated module-cache directory purely as a smoke test that the compiler/SDK/SwiftPM combination is mutually compatible — a common failure mode after an Xcode upgrade or a CLT/Xcode toolchain mismatch.

**`Scripts/test.sh`** (POSIX `sh`, `set -eu`) — detects whether the selected developer tools are the *standalone* Command Line Tools (as opposed to full Xcode). If so, it adds an extra `-F` framework search path (`$CLT/Library/Developer/Frameworks`) before invoking `swift test`, because standalone CLT ships the Swift Testing framework outside the SDK's normal search path — this mirrors equivalent logic duplicated in `Package.swift`'s `usesStandaloneCommandLineTools`/`testSwiftSettings`/`testLinkerSettings`. Forwards any extra arguments transparently (`--filter`, etc.).

**`Scripts/check-localization.py`** — a standalone Python QA script (not wired into `make`/CI as of this writing) that scans `Sources/Hisingen/Resources/*.lproj/Localizable.strings` for duplicate keys within a file and reports translation coverage gaps relative to the English base locale. It reports missing keys rather than failing on them, since `Support/L10n.swift` already falls back to English for anything missing from the active locale — an incomplete translation degrades gracefully, it isn't a build-breaking bug.

## Requirements

macOS 13 Ventura or later; Xcode 15+ or compatible Command Line Tools with Swift 5.9+. `Package.swift` declares `swift-tools-version:5.9` and `platforms: [.macOS(.v13)]`. No external Swift package dependencies — `Package.swift`'s `dependencies:` array is empty.

## Strict concurrency

Every build in CI (and recommended locally) passes `-Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`. This is not a default `swift build`/`make build` behavior — it's opt-in via `SWIFT_FLAGS`, applied explicitly in `ci.yml` and `release.yml`. See [architecture/concurrency.md](../architecture/concurrency.md).

## The `HISINGEN_EXPERIMENTAL_REMOTE` flag

```bash
HISINGEN_EXPERIMENTAL_REMOTE=1 swift build
```

Compiles in Polestar's remote-command dispatch code path (normally stubbed to always throw `RemoteCommandError.unsupported`). Never set in CI or release builds — see [security/threat-model.md](../security/threat-model.md#remote-control-surface). Setting it locally is for owner-authorized experimentation only; the real backend is still expected to reject unpaired-client write calls.

## Verifying a local build

```bash
codesign --verify --deep --strict Hisingen.app   # signature integrity
lipo -info Hisingen.app/Contents/MacOS/Hisingen   # architecture(s) present
plutil -lint Hisingen.app/Contents/Resources/Info.plist
```

CI's bundle-validation step (see [ci.md](ci.md)) runs equivalent checks automatically, plus asserting `LSUIElement == true` (the app must remain a background/accessory app with no Dock icon).
