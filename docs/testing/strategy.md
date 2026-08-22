# Testing Strategy

Hisingen migrated its entire test suite to Apple's **Swift Testing** framework (not XCTest — XCTest isn't usable under standalone Command Line Tools, which this project supports as a first-class toolchain). Every test run uses `swift test --disable-xctest --enable-swift-testing`. `Tests/HisingenTests/Unit/TestingAssertions.swift` is not a test file — it's a shim reimplementing XCTest-style assertions (`XCTAssertEqual`, `XCTUnwrap`, etc.) on top of Swift Testing's `Issue.record`, so the rest of the suite could keep familiar call sites through that migration.

## Layers

**Unit tests** (`Tests/HisingenTests/Unit/`, 18 files) — no network, no real Keychain access except where explicitly testing Keychain isolation itself (with per-test unique service names). Covers formatting, model/capability logic, error mapping, request construction (asserting exact wire format without sending it), and regression cases for specific past bugs.

**Fixture-based decode tests** — a subset of the unit tests (`GraphQLDecodingTests`, `VehicleCapabilityParsingTests`, `VolvoDecodingTests`) that decode real (sanitized) API response shapes from `Tests/HisingenTests/Fixtures/` rather than hand-built JSON strings, so decoding logic is tested against response shapes that actually occurred, including partial/error/edge-case variants. See [fixtures.md](fixtures.md).

**Integration tests** (`Tests/HisingenTests/Integration/`, 2 files) — real network calls against the live Polestar and Volvo backends. Gated by a **runtime** Swift Testing `.disabled(if:)` trait checking for required environment variables, not a compile-time flag — the files always compile, they just self-skip when credentials aren't present. `ci.yml`'s regular test step additionally passes `--skip Live` as defense-in-depth (so these suites are excluded by name, not just by their own credential gate), and they're only actually exercised via the separate `workflow_dispatch`-triggered `live-integration.yml`, or locally with real credentials. See [live integration tests](#live-integration-tests) below and [operations/ci.md](../operations/ci.md).

**UI tests** — none. There's no `XCUITest`/UI-automation target in this project; UI correctness is verified manually (see the root README's screenshots) rather than automated.

**Regression tests** (`RegressionFixTests.swift`) — named after specific past bugs (update-checker URL pointing at the right fork, "available" vs. "installed" software-version semantics not being conflated, Digital Twin climate-off never misreported as ventilating/heating, service warnings surviving a transient health-fetch failure but clearing on a genuinely clean response, rain/evening-unlocked condition detection). This is where "we broke this once, don't break it again" lives.

## What belongs in each layer

- **Pure logic** (formatting, model classification, merge rules, capability resolution, error mapping) → unit test, no fixture needed.
- **Anything that decodes a real API response shape** → fixture-based decode test, using a sanitized fixture rather than an inline JSON literal, so the test doubles as documentation of what a real response looks like.
- **Anything that constructs a request body/headers** → a `RequestConstructionTests`/`RemoteCommandTests`-style test asserting the exact wire format, without actually sending it.
- **Anything that can only be verified against the real backend** (does this endpoint still exist, does this scope still grant this access, does a real vehicle actually respond the way the DTOs assume) → integration test, credential-gated, opt-in, and — per the project's own stated policy — **read-only unless there is an extremely strong reason otherwise**.

## Test coverage matrix

| Area | Unit | Fixture | Integration | Live |
|---|---:|---:|---:|---:|
| Polestar authentication | ✓ (`ResumePathTests`) | | | ✓ (`LivePolestarIntegrationTests`) |
| Volvo authentication | | ✓ (`token-response` fixture) | | ✓ (`LiveVolvoIntegrationTests` — see known CI issue below) |
| Vehicle discovery / model identification | ✓ | ✓ | | ✓ |
| Charging (state, formatting) | ✓ (`ChargingTransitionDetectorTests`, `RegressionFixTests`) | ✓ | | ✓ (read path only) |
| Capabilities | ✓ (`VehicleCapabilityTests`, `VehicleCrossModelTests`) | ✓ (`VehicleCapabilityParsingTests`) | | |
| Notifications | ✓ (`ChargingTransitionDetectorTests`, `RegressionFixTests` rain/evening-unlocked) | | | |
| Keychain isolation | ✓ (`KeychainDraftTests`, `VolvoKeychainIsolationTests`) | | | |
| Refresh coordination (coalescing, backoff) | ✓ (`RefreshCoordinatorTests`) | | | |
| Remote command construction | ✓ (`RemoteCommandTests`, `RequestConstructionTests`) | | | ✓, but **not run by CI** — `LivePolestarRemoteCommandIntegrationTests` exists and would dispatch a real climate command, but CI's `live-integration.yml` only filters the read-only struct |
| GraphQL decoding, error handling | ✓ | ✓ (`GraphQLDecodingTests`) | | |
| Volvo REST decoding | | ✓ (`VolvoDecodingTests`, 26 tests) | | ✓ (read path only) |
| Input boundary validation | ✓ (`InputBoundaryTests`) | | | |
| UI rendering | | | | — none, manual verification only |

## Known gaps

- **No UI test coverage at all.** Verified manually before release, not automated.
- **No cross-version cache-migration test** — nothing in the suite loads an old-format `VehicleStateStore` cache and asserts graceful degradation; the behavior is understood from reading the code (`try?` decode → silent cold start) but not pinned by a test. See [architecture/persistence.md](../architecture/persistence.md#cache-design-vehiclestatestore).
- **Production Keychain integration behavior** still relies primarily on the
  Security framework itself; unit tests use isolated service names and verify
  email migration plus separation between draft and committed credentials.
- **No cross-provider concurrency test** exercises Polestar and Volvo sessions running at once, since only one brand is ever active at a time in the current UI — see [architecture/technical-debt.md](../architecture/technical-debt.md).

## Live integration tests

Two files, both real network calls, both gated to be read-only by design and by CI configuration:

- **`LivePolestarIntegrationTests.swift`** — `LivePolestarReadOnlyIntegrationTests` (authenticate, discover, fetch, sign out — no mutation) is what CI runs. A second struct, `LivePolestarRemoteCommandIntegrationTests`, actually dispatches a real `startClimate` command against a live vehicle and exists in the file, but CI's workflow filters it out explicitly (`--filter LivePolestarReadOnlyIntegrationTests`) — it would only run if someone deliberately invoked `swift test --filter LivePolestarRemoteCommandIntegrationTests` locally with real credentials, knowingly accepting that it may actuate their vehicle's climate system.
- **`LiveVolvoIntegrationTests.swift`** — `LiveVolvoReadOnlyIntegrationTests`, purely read-only (resumes a session from a pre-obtained refresh token, discovers vehicles, fetches state, verifies Keychain persistence round-trips).

**Required environment variables:**

| Test | Variables |
|---|---|
| Polestar | `HISINGEN_TEST_EMAIL`, `HISINGEN_TEST_PASSWORD`, optionally `HISINGEN_TEST_VIN` |
| Volvo | `HISINGEN_TEST_VOLVO_CLIENT_ID`, `HISINGEN_TEST_VOLVO_CLIENT_SECRET`, `HISINGEN_TEST_VOLVO_VCC_API_KEY`, `HISINGEN_TEST_VOLVO_REFRESH_TOKEN`, optionally `HISINGEN_TEST_VOLVO_VIN` |

The Volvo job's env var (`HISINGEN_TEST_VOLVO_VCC_API_KEY`) matches what `LiveVolvoIntegrationTests.swift` checks, and the workflow filters specifically to `LiveVolvoReadOnlyIntegrationTests` — so, unlike an earlier revision of this workflow, a populated secret set now actually exercises live Volvo credentials in CI rather than silently self-skipping. See [operations/ci.md](../operations/ci.md).

Neither test can wake a sleeping vehicle on its own — they read whatever state the backend currently reports, same as a normal refresh.
