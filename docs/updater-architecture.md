# Native macOS updater

Hisingen uses Sparkle 2.9.6 for direct macOS distribution. `UpdateService` is the isolated
application boundary: Sparkle parses the feed, verifies signatures, drives the native window,
installs safely, and relaunches. Vehicle/API services have no updater dependencies.

## Audit of the retired updater

The retired `UpdateChecker` read only `CFBundleShortVersionString`, queried GitHub Releases
REST every 24 hours, compared semver tags, saved an available marketing version in defaults,
and sent people to a GitHub release page to download and replace a DMG. It did not authenticate
the downloaded archive. The previous workflow built a universal app, signed/notarized when
credentials happened to be present, produced DMG/zip artifacts, and uploaded them to GitHub.
The GitHub API/manual-install flow is now removed.

## User experience and version handling

Sparkle’s standard macOS driver supplies Hisingen identity, current/new version, release date,
Markdown release notes, archive size, progress, cancellation, **Install and Relaunch**, **Later**,
and **Skip This Version**. The application menu, menu-bar context menu, and update badge bring
that native window forward; normal updates do not open GitHub.

Automatic checks run daily by default. Automatic downloading is off by default; both settings
are in Hisingen Settings. Stable uses Sparkle’s default channel. A later beta opt-in can return
`beta` from `allowedChannels(for:)`, while stable clients retain the empty/default set and never
receive prerelease entries.

`CFBundleShortVersionString` is the display version; the monotonically increasing integer
`CFBundleVersion` is what Sparkle compares. The release preparation workflow increments every
build. This correctly orders `1.3.9 → 1.4.0`, `1.4.0 (5) → 1.4.0 (6)`, `1.4.0 → 1.4.1`, and
`1.9.0 → 1.10.0`.

## Bundle packaging

Sparkle is pinned to version `2.9.6`. `make app` resolves the framework from the completed
Swift build, copies it into `Hisingen.app/Contents/Frameworks`, and links the executable with
the `@executable_path/../Frameworks` runtime search path before signing the bundle.

`Scripts/verify-updater.mjs configuration` assembles a temporary app from a clean release
build and verifies the embedded framework, executable load commands, updater metadata, and
code signature. This catches a framework that built successfully but would not be found when
the installed application launches.

## Security model

`SUPublicEDKey` is an Ed25519 public key injected only into distributable bundles.
`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` require a signed HTTPS appcast,
signed release notes, and a valid archive signature before extraction. Sparkle additionally
uses macOS code-signing checks on the replacement application. `UpdateService` logs only
non-secret operational errors in the `io.kheirallah.hisingen` / `updates` log category.

Production releases fail if Developer ID, notarization credentials, Sparkle public/private key,
or the pinned Sparkle-tools SHA-256 is missing. CI uses hardened runtime and timestamps, then
notarizes/staples and validates app and DMG with `codesign`, `spctl`, and `stapler`.

The public key must decode to exactly 32 bytes. CI passes the temporary private-key export
directly to Sparkle's `generate_appcast --ed-key-file`; it is never bundled with the application
or imported into a keychain. Before publication, an independent verifier requires a signed-feed
block, an Ed25519 archive signature, and a release-notes signature in the generated appcast.

## Release operation

One-time maintainer setup:

1. Run Sparkle `bin/generate_keys` on a secure Mac. Retain the private-key export securely.
2. Add the `SUPublicEDKey` value as Actions secret `SPARKLE_PUBLIC_ED_KEY`. Export the
   private key with `generate_keys -x sparkle-private.key`, then store the base64 encoding
   of that exported file as `SPARKLE_PRIVATE_ED_KEY` (for example,
   `base64 < sparkle-private.key | tr -d '\n'`). CI derives the corresponding public key
   and fails before publication unless it exactly matches `SPARKLE_PUBLIC_ED_KEY`.
   Set repository variable `SPARKLE_TOOLS_SHA256` to the SHA-256 of `Sparkle-2.9.6.tar.xz`.
3. Enable GitHub Pages. The Pages build serves `website/public/updates/appcast.xml` at the
   `SUFeedURL` embedded in the application.

For every version tag CI tests, builds, signs/notarizes/staples, packages the app zip and DMG,
generates a signed appcast and signed Markdown notes, publishes the release assets, updates the
Pages feed source, and dispatches the Pages deploy. No per-release manifest editing is needed.

The changelog entry may use the dated form `## [1.2.4] - 2026-08-28`. Extraction selects only
the exact tagged version and stops at the next release heading; a missing or empty section fails
the release before publication.

## Failure behavior

Network loss, rate limiting, timeout, invalid feed, absent asset, interrupted/corrupt download,
signature/code-signing failure, permission failure, unusual location, concurrent request, app
exit, and relaunch failure leave the installed version usable. Sparkle presents a clear native
error for user-initiated work and performs atomic-safe replacement only after verification.
Hisingen preferences, accounts, Keychain credentials, notification settings, charge history,
and local data are outside the app bundle and are not removed by an update.

When Sparkle aborts a manual check, `UpdateService` changes only an in-progress `.checking`
state to `.failed`, which clears the progress indicator and offers retry. An abort callback that
arrives after an available update or a later download/install state does not overwrite that state.
