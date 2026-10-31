# Releases

Release preparation creates a pull request. Production builds use an existing tag
whose resolved commit must equal the checked-out source and belong to main's
history. Changing code requires a new version/tag; there is no checkout override.

## Preparation and tagging

`Scripts/release-support.py` owns versioning and release state. Local
`make release VERSION=patch`, the Prepare Release workflow, and Auto Release use
that same implementation. Supported bumps are `patch`, `minor`, `major`, or an
exact stable `MAJOR.MINOR.PATCH` without leading zeroes. Version and build numbers
must increase. Stable version baselines exclude malformed and unrelated tags.

After successful CI for an upstream main push, Auto Release compares the tested
SHA with current main and ignores stale runs. `[skip release]` on the triggering
commit skips automation. If main already contains a new release version, it tags
that tested commit and dispatches Release on that tag. Otherwise it prepares the
version/changelog pull request. After that PR passes checks and merges, the next
successful main run tags the tested version.

Preparation never directly updates main. Bot-created branches/PRs explicitly
dispatch CI and Security because GitHub suppresses ordinary recursive events from
GITHUB_TOKEN. An interrupted preparation can reuse its branch/PR. A tagged commit
with no completed release can resume dispatch rather than disappearing as a no-op.
Only the intended release tag is pushed; unrelated local tags are not published.

## Production stages

Release jobs run under the shared `release-stable` concurrency group. A numerical
version guard also rejects distribution rollback, including reversed completion
order. `queue: max` retains up to 100 pending runs rather than replacing the
previous pending release. The monotonic guard remains necessary because queue
arrival order can differ from dispatch order. An existing tag can be dispatched
again on its own ref.

1. **Validate:** require workflow ref, tag, checkout, plist version, changelog,
   increasing build number and main ancestry to agree. Run portable checks.
2. **Test:** run credential-free deterministic tests and package validation before
   production signing credentials become available.
3. **Build:** import a Developer ID certificate, build/sign a universal app and
   upload `signed-app.zip` plus its digest/identity checkpoint.
4. **Notarize:** restore that checkpoint, submit/resume Apple's app request,
   staple and assess the app, package/sign the DMG, submit/resume its request,
   then staple/assess it. Each artifact has one notarization owner.
5. **Verify:** validate the packaged app and architectures, produce checksums,
   download checksum-pinned Sparkle tools, generate notes/appcast, and verify
   signatures against the final embedded key. Save the complete publication input.
6. **Publish:** attest provenance, create/reuse a draft release, upload assets,
   download and compare their hashes, then publish the complete release.
   Existing published releases are verified rather than overwritten.
7. **Distribute:** call the reusable Pages workflow and update Homebrew under
   monotonic version guards. A release run remains incomplete if either fails.

The publication input includes the DMG, both ZIP names, SHA256SUMS, signed feed,
signed notes and an identity/digest manifest. Pages consumes the same-run verified
site artifact; it no longer needs the release bot to commit an appcast onto main.
The Pages deployment verifies served callback/feed bytes and referenced release
assets over HTTPS. Homebrew hashes the published DMG and refuses a cask downgrade.
Missing Homebrew credentials fail preflight instead of silently skipping a channel.

## Retrying failures

Use **Re-run failed jobs** to preserve successful build checkpoints. A publication
or distribution retry should consume the saved artifact rather than recompile
source under the same version. Checkpoint manifests bind hashes to tag, source SHA,
version and build. They reject modified inputs before reuse.

Notarization saves request IDs and artifact hashes under `notary-state`. A retry
resumes the known request instead of creating another submission. Submission,
status polling, stapling and assessment have bounded operations. Permanent
rejection is fatal and retains Apple's diagnostic JSON; transient transport errors
receive bounded retries. Always-run recovery uploads preserve request state and an
already-built DMG. Signing keychains and private-key files are removed on job exit.

A full rebuild may produce different signed/archive bytes. It must not replace an
already published immutable release. Publish a new version if source or final
artifact identity changes. Verify provenance independently with:

```sh
gh attestation verify Hisingen.dmg --owner NicolasKheirallah
```

## Repository policy and rollout

`Scripts/configure-ci-protection.py` inspects/applies main protection, production
ref policies and immutable-release configuration. It saves the previous settings
in ignored local task state before applying them. Its transitional check set
matches existing main CI and omits the retired macOS 14 context. Once the new
workflow succeeds on main, `--aggregate` switches to `ci-required`.

The production environment permits main dispatches and `v*` tag refs; Release
itself requires dispatch on the requested tag. Pages permits main, gh-pages and
`v*` tag refs so it can serve the reusable release job. Release tags cannot be
updated or deleted. New immutable releases protect uploaded assets as well.

Keep signing, Apple notarization, Sparkle private keys and tap-write credentials
in `production-release`; keep vehicle test credentials in `live-integration`.
Normal CI and CodeQL use fixture configuration. GitHub does not expose saved
secret values through its API, so changing secret scope requires the original
credential material; the protection script does not retrieve or print it.

## Secrets and variables

| Name | Purpose |
| --- | --- |
| `MACOS_CERT_P12` | Base64 Developer ID Application certificate export. |
| `MACOS_CERT_PASSWORD` | Certificate export password. |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_APP_PASSWORD` | Apple notarization authentication. |
| `VOLVO_CLIENT_ID`, `VOLVO_CLIENT_SECRET`, `VOLVO_VCC_API_KEY` | Production backend build configuration; values embedded in the app are recoverable. |
| `POLESTAR_IMAGE_API_KEY` | Optional production image API configuration. |
| `SPARKLE_PUBLIC_ED_KEY` | Base64 32-byte public key embedded in the app. |
| `SPARKLE_PRIVATE_ED_KEY` | Native Sparkle private-key export, used only for signing. |
| `SPARKLE_TOOLS_SHA256` | Repository variable holding the pinned Sparkle tools archive digest. |
| `HOMEBREW_TAP_TOKEN` | Token with write access to the Homebrew tap. |

The workflow checks required configuration before its production build. Do not
change the signing key pair casually: installed clients trust their embedded
public key, so rotation needs a compatible updater migration.

## Live integration

Live Account Integration is manual and uses a dedicated test account. It never
selects remote-command suites. Polestar read-only checks complete before the
stream soak begins. Hosted soak duration is an integer from 60 to 1800 seconds;
run longer investigations locally. Discovery and execution counts must be nonzero.

Polestar requires `HISINGEN_TEST_EMAIL` and `HISINGEN_TEST_PASSWORD`; its VIN is
optional. Volvo requires `HISINGEN_TEST_VOLVO_CLIENT_ID`,
`HISINGEN_TEST_VOLVO_CLIENT_SECRET`, `HISINGEN_TEST_VOLVO_VCC_API_KEY` and
`HISINGEN_TEST_VOLVO_REFRESH_TOKEN`; its VIN is optional. If the identity provider
rotates a refresh token, refresh the environment secret through the account's
approved credential process. Disposable runner persistence does not update a saved
GitHub secret. Tests clean their local account state even after failure.
