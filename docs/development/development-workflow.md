# Development Workflow

A sensible process for changing Hisingen — proportionate to a small, single-maintainer open-source project, not enterprise process for its own sake.

```
Understand the feature/API you're changing
        │  — read the relevant api/*.md or domain/*.md doc first;
        │    if the behavior you're seeing disagrees with the doc,
        │    the code is the source of truth — fix the doc after
        ▼
Update architecture/domain docs if the change affects them
        │  — e.g. a new AppFeature, a new VehicleCapability,
        │    a new external service
        ▼
Implement the provider-side change
        │  — DTO, decode, capability wiring, error mapping
        │    (see adding-a-feature.md for the exact sequence)
        ▼
Add or update a fixture
        │  — sanitized JSON in Tests/HisingenTests/Fixtures/
        │    (see testing/fixtures.md)
        ▼
Add or update tests
        │  — decode test against the fixture, plus any
        │    behavior test (merge logic, capability resolution, etc.)
        ▼
Update the UI if the change is user-visible
        │  — new card/toggle, capability-gated visibility
        ▼
Update documentation
        │  — the specific doc(s) this change affects, not a
        │    wholesale rewrite
        ▼
Run full validation
        make doctor && make test && make app
```

## Before you start

Read the specific doc for the area you're touching, not just this workflow page — [api/polestar.md](../api/polestar.md)/[api/volvo.md](../api/volvo.md) for provider work, [architecture/capabilities.md](../architecture/capabilities.md) for anything capability-related, [domain/vehicle.md](../domain/vehicle.md) for the shared model. This documentation set is meant to save you from re-deriving behavior from scratch — if it's wrong or missing something you needed, that's worth fixing as part of your change, not just working around silently.

## Local validation, exactly what CI runs

```bash
make doctor
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
swift test --disable-xctest --enable-swift-testing -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
make app SWIFT_FLAGS="-Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency"
```

Running with the strict-concurrency flags locally catches actor-isolation mistakes before pushing — CI runs on both `macos-14` and `macos-15`, so if you have access to only one, it's still worth running this locally rather than finding out from CI. See [operations/ci.md](../operations/ci.md).

## Commit/PR expectations

There's no enforced commit-message format beyond what's visible in `git log` (conventional-ish: `feat(area): summary`, `fix(area): summary`). No required PR template, no mandatory code-owner review beyond the single maintainer. Keep changes scoped — this codebase deliberately keeps provider-specific logic out of shared layers (see [architecture/providers.md](../architecture/providers.md)); a PR that blurs that boundary is worth a second look before merging.

## When you find something wrong while working

If you discover the code and this documentation disagree, or you find a real bug adjacent to what you're working on, prefer fixing/documenting it as a small separate note (or a `technical-debt.md` entry) rather than silently working around it — that's how [architecture/technical-debt.md](../architecture/technical-debt.md) got built in the first place: honest findings from reading the implementation, not a wishlist.
