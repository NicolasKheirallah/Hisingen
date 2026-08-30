# Getting Started

## Requirements

macOS 15 Sequoia or later, and Xcode 16+ or compatible Command Line Tools with Swift 6.0+ (`Package.swift` declares `swift-tools-version:6.0`, `.macOS(.v15)`, and builds in the Swift 6 language mode). The only package dependency is Sparkle (pinned exact `2.9.6`); everything else is a system framework or hand-written.

## Clone, build, test, run

```bash
git clone https://github.com/NicolasKheirallah/hisingen.git
cd hisingen
make doctor   # verifies your toolchain is internally consistent
make test     # runs the full Swift Testing suite
make app      # builds an ad-hoc-signed releases/Hisingen.app
open releases/Hisingen.app
```

`make doctor` runs `Scripts/doctor.sh`: resolves the active `xcode-select` developer directory, prints `swiftc --version`/SDK path, and does a `swift package dump-package` smoke test in an isolated module-cache directory to catch a mismatched compiler/SDK/SwiftPM combination early, with a clear error message if that fails.

`make app` produces an **ad-hoc-signed local build**. Rebuilding changes its code-signing identity, which can cause macOS to re-prompt for Keychain access or Accessibility permission (needed for the global hotkey) on every rebuild — this is expected for local development, not a bug. Stable trust across rebuilds requires a Developer ID-signed release build; see [operations/releases.md](../operations/releases.md).

## Faster iteration: `swift run`

```bash
make run     # equivalent to `swift run`
```

Runs unbundled — no `.app` wrapper, no launch-at-login registration, no stable code-signing identity. Good for quick iteration on logic that doesn't depend on being a proper bundle (note: `Notifier` disables itself entirely when `Bundle.main.bundleURL.pathExtension != "app"` — see [architecture/technical-debt.md](../architecture/technical-debt.md) and [domain/notifications.md](../domain/notifications.md) — so notification behavior can't be exercised via `swift run`, only via `make app`).

## Running a subset of tests

```bash
swift test --disable-xctest --enable-swift-testing --filter VehicleCapabilityTests
```

`Scripts/test.sh` (what `make test` calls) forwards any extra arguments transparently, including `--filter`, and additionally handles a Command-Line-Tools-only toolchain quirk (Swift Testing ships outside the normal SDK search path under standalone CLT, so the script adds an extra `-F` framework search path in that case — mirrored by equivalent logic in `Package.swift`'s `testSwiftSettings`). See [testing/strategy.md](../testing/strategy.md).

## Signing into a real account for manual testing

You'll need your own Polestar ID or your own Volvo Developer Portal application (Client ID, Client Secret, VCC API Key registered at developer.volvocars.com, redirect URI set to `hisingen://oauth/volvo/callback`) — see the root [README.md](../../README.md#volvo-support) for the exact Developer Portal setup steps. There is no shared/test account.

## What you don't need

- No database to run, no backend to stand up — Hisingen has neither.
- No SwiftLint/SwiftFormat config — there isn't one in this repo; code style is enforced by convention and the Swift 6 language mode / complete concurrency checking (declared in `Package.swift`), not a linter (see [operations/ci.md](../operations/ci.md)).
- No API keys of Hisingen's own — Open-Meteo needs no authentication, while production update signing keys are maintainer-only CI secrets and are never used by development builds.

## Next steps

[architecture/overview.md](../architecture/overview.md) → [repository-layout.md](repository-layout.md) → [architecture/runtime.md](../architecture/runtime.md) → [testing/strategy.md](../testing/strategy.md).
