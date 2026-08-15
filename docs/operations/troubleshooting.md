# Troubleshooting & Maintainer Runbooks

Practical, symptom-first. Each entry: symptoms, likely causes, how to investigate, relevant code, possible fixes.

## Authentication fails

**Symptoms:** "Sign in failed" on the Welcome/Settings screen; repeated auth-required notifications.

**Likely causes:** wrong credentials (Polestar) or wrong/expired Developer Portal credentials (Volvo); Polestar's login page HTML changed shape (the scraped flow relies on regex-matched patterns); Volvo scope/consent issue; system clock skew affecting token expiry math.

**Investigate:** for Polestar, check whether the failure maps to `.invalidCredentials` (bad password — the "ERR001" string wasn't found in the login page) or `.callbackRejected` (the resume-path extraction failed, or `state` didn't match) — see [api/authentication.md](../api/authentication.md#polestar-scraped-oidc-login). For Volvo, check whether the OAuth authorize request itself failed (redirect never happened) vs. the token exchange failed (check `error`/`error_description` on the callback URL). `Tests/HisingenTests/Unit/ResumePathTests.swift` is the first place to check if Polestar's login page HTML shape is suspected to have changed.

**Fix:** re-enter credentials via Settings. If it's systemic (many users affected, not just one account), see the "Polestar changes authentication" runbook below.

## Refresh token no longer works

**Symptoms:** app was signed in, now silently drops back to the sign-in screen; `restoreSession` fails at launch.

**Likely causes:** the refresh token was revoked (user changed their password elsewhere, or explicitly revoked third-party access via the vendor's own account settings), or it expired from disuse.

**Investigate:** `AppDelegate.resumeStoredSession()` → provider `restoreSession(token:)` → on an auth-requiring error, the stored Keychain token is deleted and the error propagates. Check `os.log` for the specific `VehicleServiceError` case.

**Fix:** this is expected behavior, not a bug — the user needs to sign in again. If it's happening much sooner than expected (e.g. within hours of a successful login), that's worth investigating as a possible token-lifetime or refresh-timing regression — check `refreshTokenIfNeeded`'s 5-minute-before-expiry trigger logic in the relevant provider.

## Vehicle does not appear

**Symptoms:** signed in successfully, but `cars` is empty or missing the expected vehicle.

**Likely causes:** account has no vehicles registered on this brand; Polestar's dual discovery (VDMS + legacy) both returned nothing; Volvo Developer Portal app isn't subscribed to the right API product; a guest/secondary account without an account-level vehicle list.

**Investigate:** for Polestar, check whether `GetVDMSCars` and `GetConsumerCarsV2` both returned empty (see [api/polestar.md](../api/polestar.md#account-and-vehicle-discovery)) — if so, the manually-entered VIN fallback path is the only option. For Volvo, confirm the Developer Portal application actually has the Connected Vehicle API product added (a missing product subscription manifests as an empty or 403 discovery response, not a clear error).

**Fix:** for a guest/secondary account, use the manual-VIN entry field in Settings. For Volvo, verify Developer Portal product subscriptions.

## Vehicle telemetry is stale

**Symptoms:** data shown is old; "Updated X ago" keeps growing.

**Likely causes:** the vehicle itself is asleep (most common — see next entry, this isn't a bug); the refresh loop is stuck (rate-limited, or stopped due to an unhandled error); network connectivity issue not being detected.

**Investigate:** check `DiagnosticsSnapshot` (`lastSuccess`, `lastError`, `nextRefresh`, `refreshInProgress`, `sessionValid`, `networkAvailable`) — `RefreshCoordinator` republishes this after nearly every state transition. If `nextRefresh` is far in the future, check whether `rateLimitedUntil` is set. If `refreshInProgress` has been `true` for a long time, a fetch may be hung (check for a provider-side call that never times out — `URLSession` calls in this codebase generally do have timeouts, but worth confirming for any new endpoint added).

**Fix:** manual refresh from the menu; if `rateLimitedUntil` is the cause, wait it out (see [architecture/refresh-system.md](../architecture/refresh-system.md#retry-backoff) for the exact backoff schedule). If the coordinator appears genuinely stuck, a relaunch resets all in-memory refresh state.

## Vehicle shows asleep

**Not a bug.** `VehicleState.isStale(at:)` compares against `dataTimestamp` (the vehicle's own reported timestamp), not fetch time — Polestar vehicles in particular enter a low-power state while parked, and the backend serves the last sample it has, which can be hours old, without indicating an error. See [architecture/data-flow.md#freshness](../architecture/data-flow.md#freshness). If this is being reported as unexpected, first confirm whether it's *actually* stale (check `vehicleReportedAt` vs. wall-clock time) before treating it as a fetch problem.

## Charging details disappeared

**Symptoms:** charging card vanished or shows partial data mid-session.

**Likely causes:** the optional-capability fetch for that field failed and entered its backoff window (see [architecture/capabilities.md](../architecture/capabilities.md)); `mergingLastKnown` should be filling the gap from the last good value — if it isn't, check whether the relevant `AppFeature` is actually enabled (a disabled feature is never carried forward, by design) and whether `unavailableFeatures` actually lists it for this fetch (merging only kicks in when the feature both tried and failed).

**Investigate:** check `VehicleState.dataWarnings` and `unavailableFeatures` on the latest fetch. For Polestar, check whether the relevant gRPC call (`BatteryService`, `TargetSocService`, `AmpLimitService`) is in an active backoff window (`capabilityBackoff`). For Volvo, check `endpointBackoff`.

**Fix:** usually self-resolves once the backoff window expires and the next probe succeeds. If it doesn't resolve after the expected window (5 min transient / 1 hr / 6 hr for Polestar depending on error type; flat 5 min for Volvo), the underlying endpoint may genuinely be broken — see "an API response schema changes" below.

## Capability unexpectedly becomes unavailable

**Symptoms:** a control that used to be enabled is now greyed out.

**Likely causes:** the live probe went stale (>6 hours since last successful observation) and fell back to the conservative static default, which may be more restrictive than the vehicle's actual capability; or the static default itself changed in a code update.

**Investigate:** `VehicleState.probedCapabilities?.isStale` and the specific capability's static default in `VehicleCapabilityProfile.support(for:)`. Remember: **a failed probe never records an explicit "unsupported"** (except Volvo's energy-capabilities endpoint) — if a capability regressed to unavailable, it's the static table's default reasserting itself after the probe went stale, not a new negative observation. See [architecture/capabilities.md](../architecture/capabilities.md).

**Fix:** trigger a refresh to re-probe. If it's greyed out even immediately after a successful refresh, check whether the static table for that model genuinely marks it `.unavailable` or `.backendDependent` — the greyed-out state might be correct and the earlier "enabled" state might have been a stale/incorrect probe.

## Volvo/Polestar API starts returning errors broadly

See the maintainer runbooks below ("An API response schema changes," "Polestar changes authentication," "Volvo changes authentication").

## API returns HTTP 429

**Symptoms:** rate-limited errors, refreshes pausing for extended periods.

**Investigate:** `RefreshCoordinator.rateLimitedUntil` and the backoff formula in [architecture/refresh-system.md](../architecture/refresh-system.md#retry-backoff) (`Retry-After`-driven if present, else exponential capped at 15 minutes). Note Volvo never actually surfaces a `Retry-After` value today (always `nil` — see [architecture/technical-debt.md](../architecture/technical-debt.md)), so Volvo 429s always use the exponential fallback regardless of what Volvo's response header says.

**Fix:** this is the system working as intended — let it back off. If 429s are frequent even under normal single-user usage, check whether the refresh cadence itself needs adjusting, or whether a bug is causing duplicate/excessive requests (check for a coalescing failure — see [architecture/refresh-system.md#coalescing](../architecture/refresh-system.md#coalescing-how-duplicate-api-calls-are-avoided)).

## Keychain access fails

**Symptoms:** "Hisingen couldn't update its protected Keychain session" error; credentials don't persist across relaunch.

**Likely causes:** a rebuilt-with-different-signing-identity local build losing access to items saved by a previous build (expected for ad-hoc `make app` builds — see [operations/build.md](build.md)); macOS Keychain corruption (rare); the `InMemorySecretCache` returning a stale value after an external Keychain modification (very unlikely in normal use, since nothing else modifies these items).

**Investigate:** `KeychainError.status(OSStatus)`'s `errorDescription` (from `SecCopyErrorMessageString`) gives the exact `OSStatus` reason. Confirm whether this is a fresh ad-hoc rebuild (expected re-prompt) vs. a stable-identity build (unexpected).

**Fix:** for local dev, this is expected friction — see [getting-started.md](../development/getting-started.md#clone-build-test-run). For a Developer ID-signed build seeing this, it's a real bug worth investigating further.

## Launch at Login stops working

**Symptoms:** toggle is on in Settings but the app doesn't launch at login.

**Investigate:** `AppDelegate.applyLaunchAtLogin(userInitiated:)` uses `SMAppService.mainApp` — check `service.status`: `.requiresApproval` means macOS is waiting on the user to approve it in System Settings → Login Items (only opened automatically when `userInitiated: true`, i.e. from a direct Settings toggle, not from the silent launch-time call); `.notFound` or an unexpected error resets `Preferences.launchAtLogin` to `false` to avoid a UI showing "on" when it isn't actually registered.

**Fix:** direct the user to System Settings → Login Items. This only works at all when `Bundle.main.bundleURL.pathExtension == "app"` — `swift run`/unbundled builds silently no-op this entirely.

## Global shortcut (⌥P etc.) stops working

**Symptoms:** hotkeys work while Hisingen is frontmost but not globally.

**Investigate:** `StatusItemController.installGlobalHotKey()` requires `AXIsProcessTrusted()` — Accessibility permission. A rebuilt local app (new signing identity) commonly loses this grant and needs to be re-approved in System Settings → Privacy & Security → Accessibility. `refreshGlobalHotKeyAccess()` re-checks on every `applicationDidBecomeActive`, so approving it while the app is running should pick it up without a relaunch.

**Fix:** re-grant Accessibility permission. For local ad-hoc builds, this happens on every rebuild — see [operations/build.md](build.md).

## CI build fails

Check, in order: `make doctor`'s output (toolchain mismatch is the most common cause after a runner image update); whether the failure is `-strict-concurrency=complete`-specific (an actor-isolation mistake that only shows up with the flag on — reproduce locally with the same flags, see [development/development-workflow.md](../development/development-workflow.md#local-validation-exactly-what-ci-runs)); bundle-validation assertions (a signature/`Info.plist`/`LSUIElement` regression).

## Notarization fails

Check the `xcrun notarytool submit --wait` output/log directly (`notarytool log <submission-id>` if the workflow's inline output is insufficient) — common causes are an unsigned/improperly-signed nested binary, a missing hardened-runtime entitlement, or Apple-side notary service issues (transient, retry). Confirm the imported certificate is a genuine "Developer ID Application" cert (not "Apple Development" or "Mac App Distribution," which won't notarize) via `security find-identity -v -p codesigning` inside the job.

---

## Maintainer runbooks

Situations likely to happen in a project built on undocumented/semi-documented vehicle APIs.

### Polestar changes authentication

Since the login flow scrapes real HTML (`extractResumePath`, `ERR001` string matching), Polestar changing their login page markup is the single most likely thing to break Hisingen without warning. **Actionable steps:** (1) reproduce the failure and capture the actual login-page HTML Polestar now returns (sanitized of any personal data) as a new test fixture; (2) update `extractResumePath`'s regex patterns in `PolestarAPI.swift` to match the new shape, following the existing multi-pattern-fallback approach rather than replacing it with a single brittle pattern; (3) add a regression test in `ResumePathTests.swift` pinned to the new HTML shape so this specific change can't silently regress again; (4) if the flow changed more fundamentally (e.g. a new MFA step), trace it against what the official web/app client now does before implementing.

### Volvo changes authentication

Much lower risk — this is a standard, documented OAuth2/PKCE flow against a stable identity provider. If it does break: check developer.volvocars.com for announced changes first (this is the one provider where an official changelog might actually exist), then compare the actual `/as/authorization.oauth2`/`/as/token.oauth2` request/response shape against `VolvoAPI.swift`'s assumptions.

### An API response schema changes

For a fixture-covered field: the relevant decode test starts failing — that's the intended early-warning signal. Capture a sanitized real response, update the fixture (see [testing/fixtures.md](../testing/fixtures.md#updating-an-existing-fixture)), and adjust the DTO. For an uncovered field (see [testing/strategy.md](../testing/strategy.md#known-gaps) for known gaps), the symptom is a silent decode failure — the optional-capability wrapper absorbs it into `unavailableFeatures` rather than crashing, so the first sign is usually a user reporting a field went missing, not a test failure. Treat any such report as a prompt to add fixture coverage for that field, not just a one-off fix.

### A protobuf field changes (Polestar gRPC)

Since there's no `.proto` schema — every field is positionally decoded and documented only by inline comments — a field-number reassignment or type change on Polestar's side would manifest as garbage values rather than a decode error (protobuf's wire format doesn't self-describe field meaning). **Actionable steps:** compare decoded values against what the field is expected to represent (e.g. a tyre pressure decoding to an implausible number); use `PolestarGRPC`'s generic `Protobuf.fields` parser to dump all fields/wire-types/raw values for a live response and diff against the existing `parse*` function's assumptions; update the field-number mapping and add a fixture-based regression test.

### GraphQL removes or renames a field

`PolestarError.graphQL` distinguishes `data == nil` (hard failure) from `data != nil` with non-empty `errors` (soft/partial failure, absorbed as a `dataWarnings` entry) — a renamed/removed field typically surfaces as the latter first (a GraphQL error naming the specific field) before becoming a hard failure if the whole query becomes invalid. Update the query string and the corresponding DTO/`CodingKeys` together.

### C3 becomes unavailable

C3 discovery (`cnepmob.volvocars.com`) failing entirely would take down every C3-backed field at once (exterior, health/tyres, odometer fallback, OTA, schedules, location, weather fallback — see [api/polestar.md](../api/polestar.md#two-protocols-four-hosts)) while GraphQL-only fields (coarse battery/range) keep working. This asymmetry is itself a useful diagnostic: if *only* C3-sourced fields are failing while GraphQL fields are fine, suspect C3 discovery/connectivity specifically rather than a broader Polestar outage or an auth problem (which would take down both).

### PCCS/Chronos changes behavior

Affects charge target, amp limit, schedules, and remote command dispatch specifically (`api.pccs-prod.plstr.io:443`, a fixed host, no discovery step) — a fixed host means there's no discovery-layer failure mode to rule out first; a PCCS problem is either a network/outage issue or a genuine API change on Polestar's side.

### An API starts aggressively rate limiting

Confirm the per-capability/per-endpoint backoff (see [architecture/capabilities.md](../architecture/capabilities.md)) is actually being hit and respected before assuming Hisingen itself is misbehaving — check for a coalescing regression (are duplicate requests actually being deduped? see [architecture/refresh-system.md#coalescing](../architecture/refresh-system.md#coalescing-how-duplicate-api-calls-are-avoided)) as the first hypothesis, since that would present identically to "the backend got stricter."

### A new vehicle model behaves differently

Add it to `VehicleModelFamily` and give it a conservative (`.backendDependent`-heavy) static profile in `VehicleCapabilityProfile.support(for:)` rather than guessing — let runtime probing establish what it actually supports, the same way Polestar 5/6 are currently handled. See [development/adding-a-feature.md](../development/adding-a-feature.md) step 2 and [domain/capability-matrix.md](../domain/capability-matrix.md) for the existing pattern. Do not add a new `switch model` branch anywhere outside `VehicleCapabilities.swift`'s static table.

### GitHub release generation breaks

Most likely cause given the pipeline's structure: a version/tag mismatch (`Info.plist` vs. tag) or a working-tree-not-clean failure at the very start of `make release` — both are deliberately fail-fast checks, not silent. If the failure is further along (signing/notarization), see "Notarization fails" above. If `softprops/action-gh-release` itself fails, check for a GitHub Actions/token-permission change (the job needs `contents: write`, set explicitly at the job level since the workflow-level default is `read`).
