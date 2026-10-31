# Building and validating Hisingen

The app targets macOS 15 or later. CI pins Xcode through
`.github/ci-toolchain.json`; `Scripts/select-xcode.sh` verifies the selected version.
An explicitly different local `XCODE_VERSION` is a compatibility run, not proof of
the pinned hosted configuration.

| Command | Behavior |
| --- | --- |
| `make doctor` | Checks compiler, SDK, SwiftPM and SwiftUI macro compatibility. |
| `make ci` | Runs shared portable/macOS phases against the working tree, with isolated artifact output. |
| `sh Scripts/ci-local.sh --committed` | Validates an isolated archive of HEAD. |
| `make build` | Generates configuration and builds a native release binary. |
| `make universal` | Builds arm64 and x86_64 in separate scratch directories and combines them with lipo. |
| `make app` | Builds a native binary, assembles resources/frameworks, configures Sparkle and signs the app. |
| `make app-universal` | Assembles and signs the universal binary without replacing it with a native build. |
| `make dmg` | Builds the native app and packages it. Use `package-dmg` to preserve an existing universal app. |
| `make package-dmg` | Packages an existing signed app without rebuilding it. |
| `make notarize` | Submits/staples an existing app and optional DMG using retained request state. |
| `make run` | Runs the development application through the signing wrapper. |
| `make test` | Runs the test wrapper; pass explicit deterministic filters when credentials exist locally. |
| `make release VERSION=patch` | Prepares the release pull request through the shared release versioning logic. |
| `make clean` | Removes build and configured package outputs. |

The default output directory is `releases`. Override `OUTPUT_DIR` when testing
packaging. To preserve a universal app through packaging:

```sh
make app-universal OUTPUT_DIR=releases IDENTITY=- NOTARIZE=never
make package-dmg OUTPUT_DIR=releases IDENTITY=- NOTARIZE=never
REQUIRE_UNIVERSAL=true sh Scripts/validate-release.sh --artifacts releases/Hisingen.app releases/Hisingen.dmg
```

The Makefile accepts `SWIFT_FLAGS` and enforces Swift 6 concurrency through the
package settings. Debug CI additionally treats compiler warnings as errors.
Package.swift and Package.resolved define the dependency versions; avoid resolving
new versions as an incidental part of a validation run.

## Configuration and signing

Local secret injection reads environment variables or local environment files.
Values embedded in the executable are recoverable and must be treated as public;
XOR masking is not encryption. `HISINGEN_BUILD_CONFIGURATION=fixture` ignores both
local files and production API variables for reproducible credential-free checks.

Identity selection prefers an available Developer ID identity, then a development
identity. Set `IDENTITY=-` explicitly for ad-hoc validation. The production workflow
requires an imported Developer ID identity and never falls back to ad-hoc signing.

`NOTARIZE=never` disables automatic notarization. `NOTARIZE=auto` allows local
builds without credentials to skip it; `NOTARIZE=require` fails instead. Supply the
Apple ID/team/app-password variables or a `NOTARYTOOL_PROFILE`, default
`hisingen-notary`. See [releases.md](releases.md) for production handling.

## Validation interfaces

```sh
sh Scripts/validate-release.sh --source
sh Scripts/validate-release.sh --artifacts releases/Hisingen.app releases/Hisingen.dmg
```

Source validation checks tracked secret-like paths/patterns and whitespace in the
selected commit range and local diff. `CI_BASE_SHA` selects a full base commit SHA.
Artifact validation requires both inputs to exist, mounts the image, verifies
signatures, compares the packaged binary/plist with the input app, and exercises the
safe bundled launch check. `REQUIRE_UNIVERSAL=true` verifies both architectures.
Developer ID artifacts also require notarization staples and Gatekeeper assessment.

The smoke entry point `Hisingen.app/Contents/MacOS/Hisingen --ci-smoke-test` exits
before normal application initialization. It checks bundle identity, localization,
notices and framework loading. It does not prove every interactive app flow works.

The test wrapper preserves normal Swift filter/skip arguments and adds discovery,
selection validation, xUnit execution evidence and failure logs. Set
`HISINGEN_TEST_OUTPUT_DIR` to retain reports. The deterministic invocation is:

```sh
sh Scripts/test.sh --skip Live --no-parallel
```

For updater validation, `verify-updater.mjs configuration` tests key injection;
`appcast-self-test` exercises real Ed25519 signatures and tampering controls. The
`appcast` command requires the generated feed, archive, notes and final bundle plist:

```sh
node Scripts/verify-updater.mjs appcast updates/appcast.xml Hisingen.app.zip updates/Hisingen.app.md Hisingen.app/Contents/Info.plist v1.2.3
```

The verifier parses XML, verifies feed/archive/notes signatures, checks byte lengths
and version/URL metadata, and compares the archive's embedded plist with the final
bundle. It verifies the complete notes file, including Sparkle's signing warning.
