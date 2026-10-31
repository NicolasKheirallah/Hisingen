# Continuous integration

Eight workflows live in `.github/workflows/`: CI, Security, Dependency Review,
Deploy site, Live Account Integration, Auto Release, Prepare Release, and Release.

## Required validation

`ci.yml` runs on main pushes, main pull requests, merge groups, and manual dispatch.
It cancels superseded runs for the same branch or pull request. Its jobs are:

| Job | Contract |
| --- | --- |
| `portable-checks` | Shared lint, source hygiene, localization, documentation, notices, VIN scoping, contrast, source invariants, updater checks, and release/test-runner regressions. |
| `build-and-test (macos-15)` | Native arm64 build/tests and universal app/DMG packaging on the deployment baseline. |
| `build-and-test (macos-26-intel)` | Native x86_64 build/tests on the newer supported runtime. |
| `ci-required` | Runs even after failure/cancellation and accepts only success from every required validation job. |

Temporary compatibility jobs emit the previous required-check names during the
protection migration. They depend on the complete portable phase. After the new
workflow succeeds on main, switch the main ruleset to `ci-required` with:

```sh
python3 Scripts/configure-ci-protection.py --apply --aggregate --enable-immutable
```

The command refuses the aggregate migration until that check has succeeded on
main. Its default migration mode requires the existing check names and removes
the obsolete macOS 14 requirement. Inspect settings without changing them by
omitting `--apply`. See [releases.md](releases.md) for production restrictions.

## Shared local and hosted phases

`Scripts/ci-checks.sh portable` and `Scripts/ci-checks.sh macos` are the executable
phase definitions. Workflows and local CI call these scripts rather than copying
the validation commands into multiple places.

```sh
make ci
sh Scripts/ci-local.sh --committed
```

The first command checks the working tree and rejects untracked build inputs.
The second checks an isolated archive of HEAD, so uncommitted changes cannot make
a broken commit appear healthy. Neither command proves the other hosted OS and
architecture lane passes. Local packaging uses a temporary output directory and
prints its location so failures retain diagnostics without deleting existing apps.

The toolchain contract is `.github/ci-toolchain.json`. Blocking hosted jobs pin
Xcode 26.3; they do not silently select a newer installed Xcode. Local compatibility
runs can set `XCODE_VERSION` explicitly. Node, Python, Go and ShellCheck versions
are pinned in the workflows; ShellCheck's downloaded archive has a checked digest.
GitHub supports `queue: max`, which actionlint 1.7.12 does not yet parse. The
shared lint command validates that exact extension and its cancellation contract,
then normalizes only the validated queue field before invoking actionlint. Invalid
values, duplicates, nesting and conflicting cancellation fail behavioral checks;
other workflow diagnostics remain fatal.

SwiftPM repository and binary-artifact caches are keyed by dependency/toolchain
inputs. Compiled products and generated credentials are not shared caches.

## Credential-free tests and packaging

Normal CI sets `HISINGEN_BUILD_CONFIGURATION=fixture`. Secret injection then
ignores local environment files and supplied production API variables, and makes
the same fixture configuration on every regeneration. CodeQL also builds without
production credentials.

The test wrapper discovers tests, applies the execution filters, rejects empty
selection and integration suites leaking into the deterministic set, then records
execution results. `HISINGEN_TEST_OUTPUT_DIR` selects the report directory. xUnit
results, selected-test metadata and execution summaries distinguish discovery from
actual execution; a zero-test or all-disabled run fails.

Tests still use global serialization while shared-resource tests require it.
Timing-sensitive suites use injected clocks and explicit events with cancellation
and bounded failure deadlines. A timeout is a diagnostic bound, not an assertion
that a scheduler must run within a tiny real-time window.

Universal packaging preserves the built app and uses `package-dmg` rather than
rebuilding it. Mandatory artifact validation mounts the DMG, checks the packaged
app's signatures, plist and architectures, compares it with the input app, and
runs `--ci-smoke-test`. That entry path checks resources and Sparkle loading before
creating AppDelegate, opening persistence, or starting account/network activity.

## Diagnostics and security

Build/test jobs upload results and diagnostic files even after failure, with
bounded retention. Their summaries record commit, runner and selected toolchain.
Build failures remain failures when output is piped into a log. Test discovery
compiles the app and test targets once, with coverage and warnings-as-errors;
execution reuses that build. Discovery compiler diagnostics are retained even
when the build fails before tests start.

`security.yml` runs Swift CodeQL on main changes, on its weekly schedule, and by
manual dispatch. Its fixture build uses the same pinned Xcode. CodeQL is advisory
to publication unless its result is explicitly added to the repository policy;
compilation success alone is not a claim that no security alerts exist.

Dependency Review runs for pull requests and rejects high/critical dependency
findings. Dependabot tracks pinned Actions and Swift dependencies. The package
now includes Sparkle and gRPC/NIO dependencies; see Package.resolved and the
third-party notices for the resolved set.

Source hygiene checks selected committed changes as well as local edits. Its
filename/content patterns are narrow guardrails. GitHub secret scanning and push
protection provide separate token detection; neither is a guarantee that source
contains no credentials.

## Pages and live tests

Pages serves the Volvo OAuth callback and the signed Sparkle appcast. Release
calls the reusable Pages workflow with its verified release artifact and waits
for deployment. The deployment verifier checks byte equality over HTTPS and
availability/length of referenced release assets. A callback-only main deployment
preserves the latest published release feed instead of restoring a stale source
copy.

Live integration remains manual and separate from deterministic CI. Hosted soak
duration must be 60 through 1800 seconds; longer soaks run locally. Polestar
read-only tests and its soak run sequentially to avoid competing account sessions.
The test wrapper rejects a filter that matches no tests. No ordinary CI job sends
vehicle commands. See [releases.md](releases.md) for account credentials.

## Manual research validators

`audit-polestar-coverage-doc.mjs`, `verify-page-coverage.mjs` and historical design
checks require local research documents or render assets that are intentionally
absent from the committed source tree. Run them manually when working on those
artifacts. Required portable checks operate only on versioned inputs; they do not
turn missing private research files into a hosted CI dependency.
