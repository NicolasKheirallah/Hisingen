# Testing Strategy

Hisingen migrated its entire test suite to Apple's **Swift Testing** framework (not XCTest; XCTest isn't usable under standalone Command Line Tools, which this project supports as a first-class toolchain). Every test run uses `swift test --disable-xctest --enable-swift-testing`. `Tests/HisingenTests/Unit/TestingAssertions.swift` is not a test file; it's a shim reimplementing XCTest-style assertions (`XCTAssertEqual`, `XCTUnwrap`, etc.) on top of Swift Testing's `Issue.record`, so the rest of the suite could keep familiar call sites through that migration.

## Layers

**Unit tests** (`Tests/HisingenTests/Unit/`, 18 files): no network, no real Keychain access except where explicitly testing Keychain isolation itself (with per-test unique service names). Covers formatting, model/capability logic, error mapping, request construction (asserting exact wire format without sending it), and regression cases for specific past bugs.

**Fixture-based decode tests**: a subset of the unit tests (`GraphQLDecodingTests`, `VehicleCapabilityParsingTests`, `VolvoDecodingTests`) that decode real (sanitized) API response shapes from `Tests/HisingenTests/Fixtures/` rather than hand-built JSON strings, so decoding logic is tested against response shapes that actually occurred, including partial/error/edge-case variants

**Integration tests** (`Tests/HisingenTests/Integration/`, 2 files): real network calls against the live Polestar and Volvo backends. Gated by a **runtime** Swift Testing `.disabled(if:)` trait checking for required environment variables, not a compile-time flag; the files always compile, they just self-skip when credentials aren't present. `ci.yml`'s regular test step additionally passes `--skip Live` as defense-in-depth (so these suites are excluded by name, not just by their own credential gate), and they're only actually exercised via the separate `workflow_dispatch`-triggered `live-integration.yml`, or locally with real credentials. See [live integration tests](#live-integration-tests) below and [operations/ci.md](../operations/ci.md).

**UI tests**: none. There's no `XCUITest`/UI-automation target in this project; UI correctness is verified manually (see the root README's screenshots) rather than automated.

**Regression tests** (`RegressionFixTests.swift`): named after specific past bugs (update-checker URL pointing at the right fork, "available" vs. "installed" software-version semantics not being conflated, Digital Twin climate-off never misreported as ventilating/heating, service warnings surviving a transient health-fetch failure but clearing on a genuinely clean response, rain/evening-unlocked condition detection). This is where "we broke this once, don't break it again" lives.

## What belongs in each layer

- **Pure logic** (formatting, model classification, merge rules, capability resolution, error mapping) → unit test, no fixture needed.
- **Anything that decodes a real API response shape** → fixture-based decode test, using a sanitized fixture rather than an inline JSON literal, so the test doubles as documentation of what a real response looks like.
- **Anything that constructs a request body/headers** → a `RequestConstructionTests`/`RemoteCommandTests`-style test asserting the exact wire format, without actually sending it.
- **Anything that can only be verified against the real backend** (does this endpoint still exist, does this scope still grant this access, does a real vehicle actually respond the way the DTOs assume) → integration test, credential-gated, opt-in and, per the project's own stated policy, **read-only unless there is an extremely strong reason otherwise**.

## Test coverage matrix

| Area | Unit | Fixture | Integration | Live |
|---|---:|---:|---:|---:|
| Polestar authentication | ✓ (`ResumePathTests`) | | | ✓ (`LivePolestarIntegrationTests`) |
| Volvo authentication | | ✓ (`token-response` fixture) | | ✓ (`LiveVolvoIntegrationTests`; see known CI issue below) |
| Vehicle discovery / model identification | ✓ | ✓ | | ✓ |
| Charging (state, formatting) | ✓ (`ChargingTransitionDetectorTests`, `RegressionFixTests`) | ✓ | | ✓ (read path only) |
| Capabilities | ✓ (`VehicleCapabilityTests`, `VehicleCrossModelTests`) | ✓ (`VehicleCapabilityParsingTests`) | | |
| Notifications | ✓ (`ChargingTransitionDetectorTests`, `RegressionFixTests` rain/evening-unlocked) | | | |
| Keychain isolation | ✓ (`KeychainDraftTests`, `VolvoKeychainIsolationTests`) | | | |
| Refresh coordination (coalescing, backoff) | ✓ (`RefreshCoordinatorTests`) | | | |
| Remote command construction and coordination | ✓ (`RemoteCommandTests`, `RequestConstructionTests`) | | | (live command execution is intentionally excluded) |
| GraphQL decoding, error handling | ✓ | ✓ (`GraphQLDecodingTests`) | | |
| Volvo REST decoding | | ✓ (`VolvoDecodingTests`, 26 tests) | | ✓ (read path only) |
| Input boundary validation | ✓ (`InputBoundaryTests`) | | | |
| UI rendering | | | | none, manual verification only |

## Known gaps

- **No UI test coverage at all.** Verified manually before release, not automated.
- **No cross-version cache-migration test**: nothing in the suite loads an old-format `VehicleStateStore` cache and asserts graceful degradation; the behavior is understood from reading the code (`try?` decode → silent cold start) but not pinned by a test. See [architecture/persistence.md](../architecture/persistence.md#cache-design-vehiclestatestore).
- **Production Keychain integration behavior** still relies primarily on the
  Security framework itself; unit tests use isolated service names and verify
  email migration plus separation between draft and committed credentials.
- **No cross-provider concurrency test** exercises Polestar and Volvo sessions running at once, since only one brand is ever active at a time in the current UI; see [architecture/technical-debt.md](../architecture/technical-debt.md).

## Live integration tests

Two files, both real network calls, both gated to be read-only by design and by CI configuration:

- **`LivePolestarIntegrationTests.swift`**: `LivePolestarReadOnlyIntegrationTests` is the complete Polestar live suite: authenticate, discover, fetch, restore a session, and sign out. It contains no remote commands, API probing, schema introspection, or sensitive diagnostic output.
- **`LiveVolvoIntegrationTests.swift`**: `LiveVolvoReadOnlyIntegrationTests`, purely read-only (resumes a session from a pre-obtained refresh token, discovers vehicles, fetches state, verifies Keychain persistence round-trips).

**Required environment variables:**

| Test | Variables |
|---|---|
| Polestar | `HISINGEN_TEST_EMAIL`, `HISINGEN_TEST_PASSWORD`, optionally `HISINGEN_TEST_VIN` |
| Volvo | `HISINGEN_TEST_VOLVO_CLIENT_ID`, `HISINGEN_TEST_VOLVO_CLIENT_SECRET`, `HISINGEN_TEST_VOLVO_VCC_API_KEY`, `HISINGEN_TEST_VOLVO_REFRESH_TOKEN`, optionally `HISINGEN_TEST_VOLVO_VIN` |

The Volvo job's env var (`HISINGEN_TEST_VOLVO_VCC_API_KEY`) matches what `LiveVolvoIntegrationTests.swift` checks, and the workflow filters specifically to `LiveVolvoReadOnlyIntegrationTests`; so, unlike an earlier revision of this workflow, a populated secret set now actually exercises live Volvo credentials in CI rather than silently self-skipping. See [operations/ci.md](../operations/ci.md).

Neither test can wake a sleeping vehicle on its own; they read whatever state the backend currently reports, same as a normal refresh.

## The deterministic suite runs serialized

Every gate that runs the deterministic suite passes `--no-parallel`: `ci.yml`,
`release.yml`, `Scripts/ci-local.sh`, `Scripts/release.sh`, and the `Makefile`'s `test` target.
Add it to any new caller.

The suite is not parallel-safe under a small runner, because a large part of it is
schedule-sensitive by design. Tests like `RefreshCoordinatorStreamTests` and
`PopoverRefreshCoalescerTests` assert on *when* the app will do something next — a confirmation
poll 50 ms out, a coalescing window of 120 ms — and they drive real timers to get there. Those
assertions hold while the actor they share has room to run them. On a three-core GitHub runner,
132 suites at once do not leave that room: a 120 ms coalescing window has been measured taking
over 10 s to fire, twice, on two different workflows. The failure says nothing about the
coalescer and everything about the runner.

Serializing costs about twice the wall clock (roughly 28 s against 13 s on a developer Mac,
about ten minutes for the whole `build-and-test` job) and removes the whole class of noise, so a
red run means a real defect. Omitting `--no-parallel` still runs the suites in parallel, so drop
it deliberately if you want to reproduce a contention bug.

This is a property of the runner, not of the tests: if the suite moves to a larger runner, or
the timing-sensitive suites get injected clocks, re-measure before assuming serialization is
still needed.

## Test framework (2026-08-22)

The suite is **Swift Testing** (`import Testing`) exclusively. The current CommandLineTools
toolchain cannot compile `import XCTest`, so new test files must use `@Test` structs with
`#expect`/`#require`. Fixture JSON files under the tests target cover provider decoding;
wire-level proto fixtures are built inline with the `Protobuf.*Field` helpers.
