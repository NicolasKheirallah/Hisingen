# ADR-0012: One Remote Command dispatch authority; brand policy lives in the gate

Status: Accepted

## Context

Remote Commands reach Hisingen through three entry points: the Controls tab,
`hisingen://` deep links, and Shortcuts intents. Each entry point used to hold
its own opinion about which commands a vehicle accepts:

- The deep-link router refused *every* Polestar write with a "paired mobile
  devices only" notice, while the Controls tab dispatched the same Polestar
  commands through the C3 command client. The two surfaces contradicted each
  other for the identical command.
- Shortcuts intents gated on a VIN-prefix heuristic (`"YV"` = Volvo) and a
  private copy of the Volvo restricted-scopes precondition, and dispatched by
  round-tripping through `NSWorkspace.open` + the URL router, then polling the
  command audit table for up to 45–60 s to learn the outcome.
- The router had no tests at all — and it is the security boundary for
  `hisingen://lock`.
- The Volvo "Approved permissions" (`volvoRestrictedScopesEnabled`)
  precondition was enforced only by the intents' pre-flight; the Controls tab
  let the command reach the provider and fail there with a permission error.

## Decision

`CommandCoordinator.perform` is the one dispatch authority: an awaited call
that returns the outcome (`RemoteCommandDispatchOutcome`), with the human
presentation still flowing through `presentResult`. The URL router and
Shortcuts intents are thin adapters over it:

- The router's brand ban is deleted; brand policy lives in `CapabilityGate`
  and `ProviderCommandCatalog` — the same single answer every surface gets.
  The one remaining per-brand notice (Volvo charge-target) is a capability
  fact, not policy.
- Shortcuts intents await the shell's readiness (`AutomationHandoff.install`,
  installed by `AppDelegate` once composition completes) and then dispatch
  in-process. The `NSWorkspace.open` hop and the audit-table poll are deleted;
  the audit table keeps its durable role but is no longer a result bus.
- The Volvo restricted-scopes precondition moved into `CapabilityGate`
  (`.requiresAccountApproval`), so the Controls tab, deep links, and intents
  refuse identically instead of failing at different layers.

## Alternatives considered

- **Keep the deep-link Polestar ban.** It contradicts the in-app path for the
  same command and has no supporting policy; a deep-link command without
  command-client authorization fails with the same error the Controls tab
  shows. Not kept.
- **Keep a URL round-trip for cold launches only.** Two dispatch paths for the
  same surface; the readiness wait (a continuation list installed at the end
  of `applicationDidFinishLaunching`) makes one path safe for both warm and
  cold starts.

## Consequences

- `hisingen://lock` (and the other write deep links) now work on Polestar — a
  deliberate behavior change; users get the same gate refusals the Controls
  tab shows.
- Shortcuts get instant results (the awaited provider outcome) instead of a
  500 ms-poll with a 45–60 s worst case.
- The entry points are testable through the dispatch seam for the first time
  (`RemoteCommandDispatchTests`); the coordinator's ordering invariants are
  unchanged.
