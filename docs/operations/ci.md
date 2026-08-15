# CI

Four GitHub Actions workflows live in `.github/workflows/`: `ci.yml`,
`security.yml`, `live-integration.yml`, and `release.yml`. All actions used
across them are pinned to commit SHAs with a version comment (e.g.
`actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.0.0`) —
preserve that pinning style when bumping any of them. This document covers
`ci.yml` and `security.yml`; see [releases.md](./releases.md) for
`release.yml` and `live-integration.yml`.

```mermaid
flowchart LR
    subgraph Push["push to main / any PR"]
        Lint["ci.yml: lint-workflows-and-scripts<br/>actionlint + shellcheck"]
        L10n["ci.yml: check-localization<br/>duplicate-key detection + coverage report"]
        Docs["ci.yml: check-docs<br/>broken links + unbalanced fences"]
        CI["ci.yml: build-and-test<br/>macos-14 + macos-15 matrix<br/>build, test, bundle validation"]
        Sec["security.yml<br/>CodeQL (Swift) + Dependency Review"]
    end
    subgraph Manual["workflow_dispatch"]
        Live["live-integration.yml<br/>real Polestar/Volvo calls, read-only"]
    end
    subgraph Tag["push tag v*"]
        Release["release.yml<br/>test → sign → notarize → DMG → GH Release"]
    end
```

## `ci.yml`

**Trigger:** `push` to `main`, and every `pull_request`.
**Permissions:** `contents: read`.
**Concurrency:** `ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}`, cancels in-progress runs on a new push to the same PR/branch.
**Secrets:** none.

### Job `lint-workflows-and-scripts` (ubuntu-latest, ~2 min)

Validates the automation itself before spending macOS runner time: `actionlint`
(installed via `go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12`
— the Go module proxy checksum-verifies this against sum.golang.org, so it
doesn't need its own pinned third-party Action) against every workflow file,
and `shellcheck` against `Scripts/*.sh`.

### Job `check-localization` (ubuntu-latest, ~1 min)

Runs `Scripts/check-localization.py` against every `*.lproj/Localizable.strings`
file. **Fails on duplicate keys** within a single locale file (whichever line
wins is unspecified — a real bug). **Reports, but does not fail on**,
translation coverage relative to the base `en` locale — `L10n.swift` falls
back to English for any key missing from the active locale, so an
incomplete/stub locale is expected, not a defect.

### Job `check-docs` (ubuntu-latest, ~1 min)

Runs `Scripts/check-docs-links.py` against `README.md`, `changelog.md`,
`TERMS.md`, and everything under `docs/`. Fails on a relative Markdown link
that doesn't resolve to a real file, or an unterminated code fence
(``` ``` ```) — the two cheapest, highest-signal documentation defects to
catch automatically. Does not check external `http(s)` links (no network
access in this job) or Mermaid diagram *syntax* (only that fences are
balanced) — Mermaid syntax errors are still visible whenever the page
actually renders on GitHub.

### Job `build-and-test` (matrix: `macos-14`, `macos-15`, `fail-fast: false`, 20-minute timeout)

Checkout → cache `.build` (keyed on
`${{ matrix.os }}-spm-${{ hashFiles('Package.resolved','Package.swift') }}`)
→ `swift --version` + `make doctor` → (macos-15 leg only) warn via
`::warning::` if `/Applications/Xcode_16.2.app` is missing from the runner
image, since `release.yml` hard-pins that exact version — an early canary for
release-toolchain drift, checked on every PR rather than only discovered
during an actual release → `swift build -Xswiftc -strict-concurrency=complete
-Xswiftc -warn-concurrency` → `swift test --disable-xctest --enable-swift-testing
--skip Live -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`
→ `make app SWIFT_FLAGS="..."` → bundle validation: binary executable bit
set, `plutil -lint` on `Info.plist`, `lipo -verify_arch arm64`, `codesign
--verify --deep --strict`, and an explicit assertion that `LSUIElement ==
true`; and that `Info.plist`'s `CFBundleIconFile` actually resolves to a
present file under `Contents/Resources/`.

`--skip Live` is defense-in-depth, not the only safeguard: the live
integration suites already gate themselves on credential env vars via Swift
Testing's `.disabled(if:)` trait, and CI never sets those secrets — but one
of those suites (`LivePolestarRemoteCommandIntegrationTests`) dispatches a
real `startClimate` command, so a second, independent guard (skip anything
named `Live` outright) means that stays true even if those credentials were
ever accidentally added as repository-level rather than
environment-scoped secrets.

**No Swift linting step exists** — no SwiftLint/SwiftFormat configuration
anywhere in the repo (workflow/shell-script linting now does exist, via
`lint-workflows-and-scripts` above). The strict-concurrency compiler flags
are the closest thing to automated Swift style/correctness enforcement
beyond the test suite itself.

**No signing/notarization** — ad-hoc (`IDENTITY` defaults to `-`).

**Artifacts:** none produced.

**Fails on:** a bad toolchain (`make doctor`), a build or test failure, an
actionlint/shellcheck finding, a duplicate localization key, a broken docs
link/unterminated fence, or any bundle-validation assertion failing
(including the `LSUIElement` check — a regression there would silently turn
Hisingen into a Dock-visible app, which this check exists specifically to
catch).

## `security.yml`

**Trigger:** `push` to `main`, every `pull_request`, and a weekly schedule
(Mondays 04:17 UTC).
**Secrets:** none.

### Job `codeql` (macos-15, `security-events: write`, ~10–15 min)

CodeQL Swift analysis using `build-mode: manual` with a plain `swift build`
(the same command CI/Makefile use), rather than the `autobuild` heuristic, so
the analyzed build matches what actually ships. Results land under the
repo's **Security → Code scanning alerts**.

### Job `dependency-review` (ubuntu-latest, `pull_request` only, ~1 min)

Diffs the dependency graph between base and head (GitHub Actions used in
workflows are part of that graph; Hisingen has zero external SwiftPM
dependencies today). Fails on `high`/`critical` severity findings only.

Neither `security.yml` job is currently wired into required branch checks
(see the branch protection recommendation in [releases.md](./releases.md)) —
treat them as advisory signal to triage unless you decide otherwise.

## `live-integration.yml` and `release.yml`

Covered in full in [releases.md](./releases.md), including the secrets
checklist for both.

## Troubleshooting

- **Bundle validation fails**: re-run locally with `make app` then run the
  same `plutil`/`lipo`/`codesign` commands from `ci.yml` directly.
- **`lint-workflows-and-scripts` fails**: `actionlint` output includes the
  exact file/line; most failures are invalid `${{ }}` expressions or
  step-output typos.
- **CodeQL fails to build**: check the "Build (same command as CI)" step
  logs first — if `swift build` fails there, it's a real build break, not a
  CodeQL-specific issue.
