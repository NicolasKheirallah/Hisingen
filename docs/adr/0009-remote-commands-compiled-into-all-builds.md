# ADR-0009: Remote Command Support Is Compiled Into All Builds

- **Status:** Accepted
- **Date:** 2026-08-19
- **Decision owners:** Hisingen maintainers
- **Scope:** Remote vehicle commands and feature gating

## Context

Hisingen supports vehicle information and, where the provider and vehicle permit it, remote vehicle commands.

Remote-command availability is not uniform.

Whether a particular command can be used depends on several factors, including:

- vehicle manufacturer;
- vehicle model;
- model year;
- market;
- vehicle configuration;
- provider account permissions;
- API capabilities;
- authentication state;
- current vehicle state; and
- Hisingen's implementation and validation of that capability.

Earlier development treated some remote-command functionality as experimental and considered excluding or conditionally compiling parts of that functionality from normal builds.

That approach created unnecessary differences between development and release builds and made capability handling harder to reason about.

It also mixed two separate concerns:

1. whether Hisingen contains an implementation for a command; and
2. whether that command should be available to a particular user, vehicle, or session.

Those concerns should be handled separately.

## Decision

Remote-command implementations that are part of Hisingen are compiled into normal application builds.

Availability is controlled at runtime.

A command being present in the binary does **not** mean that it is:

- supported by every provider;
- supported by every vehicle;
- exposed in the UI;
- enabled by default;
- safe to execute in every vehicle state; or
- verified for every model or market.

Runtime capability checks, provider support, authentication requirements, vehicle state, and explicit feature policy determine whether a command is available.

## Runtime Gating

Remote commands must be gated using the strongest available runtime information.

Where applicable, this includes:

- provider-reported capabilities;
- vehicle model and model year;
- market or region;
- required authentication permissions;
- account authorization;
- current vehicle state;
- command-specific preconditions;
- Hisingen capability policy; and
- whether the command has been sufficiently validated for production use.

The application should prefer an explicit unavailable state over attempting an unsupported or insufficiently validated command.

## UI Behaviour

The user interface must not infer that every compiled command is usable.

Commands should only be presented as actionable when Hisingen has enough information to determine that the operation is appropriate for the current vehicle and session.

Depending on the command, Hisingen may:

- hide it;
- show it as unavailable;
- disable it with an explanation;
- require confirmation;
- require local device-owner authentication; or
- reject execution before making a provider request.

The UI should communicate capability limitations without requiring users to understand provider implementation details.

## Provider Differences

Polestar and Volvo do not expose identical remote-control capabilities.

Hisingen must therefore model remote controls as provider- and vehicle-specific capabilities rather than as one universal feature set.

A command implemented for one provider must not automatically be assumed to exist for another.

Likewise, support observed on one vehicle model, model year, account, or market must not automatically be generalized to all vehicles.

## Capability Model

Documentation and code should distinguish at least the following states:

1. **Known provider capability**  
   The underlying provider or vehicle is known to support the operation.

2. **Implemented in Hisingen**  
   Hisingen contains an implementation for the operation.

3. **Validated**  
   The implementation has sufficient test or real-world validation for the supported configuration.

4. **Exposed to the user**  
   The command is intentionally available through the current Hisingen UI.

5. **Available now**  
   Current authentication, capability, and vehicle-state checks allow execution.

These states must not be treated as interchangeable.

## Safety Requirements

Remote commands can affect a physical vehicle and therefore require stricter handling than read-only telemetry.

Implementations must:

- validate required inputs before sending a request;
- verify authentication and authorization state;
- apply provider- and vehicle-specific capability checks;
- enforce known command preconditions;
- avoid automatic retries where repeated execution could have side effects;
- handle uncertain provider responses conservatively;
- surface failures clearly;
- avoid presenting an unconfirmed command as successful; and
- protect sensitive operations with additional confirmation where appropriate.

A request being accepted by a provider does not necessarily mean the physical operation completed successfully.

Where available, Hisingen should distinguish between:

- request accepted;
- operation pending;
- operation completed;
- operation rejected; and
- outcome unknown.

## Compile-Time Feature Flags

Compile-time flags should not be the primary mechanism for controlling normal remote-command availability.

They create separate application variants and can allow differences between:

- developer testing;
- continuous integration;
- beta builds; and
- public releases.

Runtime gating gives Hisingen one implementation that can be tested consistently while still preventing unsupported functionality from being exposed.

Compile-time exclusion remains appropriate for exceptional cases such as:

- unfinished code that must not ship;
- development tooling;
- test-only infrastructure;
- provider research code; or
- functionality that has not passed the project's security and safety threshold.

Such exceptions should be explicit and temporary.

## Experimental Functionality

Functionality that is still being researched or validated must not become production-accessible merely because its implementation exists.

Experimental functionality should be isolated using appropriate runtime policy, development-only tooling, or separate private research material.

The production application should not expose commands whose safety, authorization model, or provider behaviour has not been sufficiently understood.

## Public Documentation Boundary

This ADR documents the architectural decision to compile supported remote-command implementations into normal builds and control their availability at runtime.

It intentionally does **not** document provider reverse-engineering details.

Public ADRs and architecture documentation should not include unnecessary material such as:

- first-party application identifiers;
- internal provider client identifiers;
- undocumented authentication scope experiments;
- provider-side allowlist behaviour;
- captured authentication requests or responses;
- private or internal service topology;
- undocumented internal method names;
- probing transcripts;
- raw production API responses;
- account-specific testing results; or
- step-by-step research procedures used to discover undocumented functionality.

Such information is not required to understand this architectural decision.

Where low-level research is necessary for maintenance, it should be kept in appropriately controlled development or research material rather than copied into public architectural documentation.

## Source-Code Comments

Production source should explain **why** an implementation behaves a certain way without unnecessarily preserving the investigation used to discover that behaviour.

Prefer comments such as:

> Remote commands require a provider-specific authorization context.

rather than comments containing:

- captured provider identifiers;
- experimental credentials;
- exact discovery transcripts;
- account-specific results;
- speculative provider internals; or
- historical probing notes.

Comments should describe the contract Hisingen relies on, not serve as a reverse-engineering notebook.

## Testing

Remote-command functionality should be tested at several levels.

### Unit Tests

Unit tests should cover:

- capability evaluation;
- request construction;
- input validation;
- response parsing;
- state transitions;
- failure handling; and
- command-specific preconditions.

Tests should use sanitized fixtures and must not require real user credentials.

### Integration Tests

Read-only integration tests may validate provider compatibility where suitable test accounts are available.

Tests that can cause a physical vehicle action require additional care and must never run automatically as part of normal pull-request CI.

Any live command test must:

- be explicitly invoked;
- use an authorized test account and vehicle;
- clearly identify that a physical action can occur;
- minimize the scope of the operation;
- avoid destructive behaviour; and
- never expose account credentials or tokens in logs.

### Release Validation

Release validation should confirm that:

- production UI gating matches the intended capability policy;
- unsupported commands are unavailable;
- development-only controls are not unintentionally exposed;
- no research-only credential or capture material is bundled; and
- logging does not expose authentication material.

## Security Considerations

Compiling a remote-command implementation into the application increases the importance of runtime authorization and capability enforcement.

Security must not rely on a command being difficult to discover in the binary.

A user with access to their local application can inspect or modify client-side software.

Provider authorization and Hisingen's own validation must therefore remain the relevant control boundaries.

Sensitive authentication information must never be placed in:

- ADRs;
- public troubleshooting guides;
- screenshots;
- fixtures;
- logs;
- crash reports; or
- issue templates.

## Privacy Considerations

Remote-command functionality may involve sensitive vehicle information.

Documentation and diagnostics should minimize exposure of:

- VINs;
- precise vehicle location;
- account identifiers;
- authorization responses;
- access or refresh tokens; and
- command histories that could identify a user's vehicle or behaviour.

Public documentation should use sanitized examples.

## Consequences

### Positive

- Development and release builds share the same command implementation.
- Runtime capability logic becomes the primary source of truth.
- Testing more closely represents what is shipped.
- Provider and vehicle differences can be modeled explicitly.
- Commands can be enabled as support becomes sufficiently validated without restructuring the build.
- Public architecture documentation remains understandable without exposing unnecessary provider internals.

### Negative

- Compiled code may contain implementations for commands that are unavailable to a particular user.
- Runtime gating becomes security- and safety-sensitive.
- Capability modelling requires ongoing maintenance as provider behaviour changes.
- A compiled implementation can potentially be inspected even when the UI does not expose it.
- Experimental functionality must be carefully separated from supported production behaviour.

## Alternatives Considered

### Compile remote commands only into experimental builds

Rejected as the default architecture.

This creates different application variants and makes it easier for release and development behaviour to diverge.

It remains appropriate for genuinely unfinished or research-only functionality.

### Enable every implemented command

Rejected.

Implementation existence alone is not sufficient evidence that a command is supported, authorized, or safe for a particular vehicle.

### Hard-code capability decisions by vehicle model

Rejected as the sole strategy.

Static knowledge may be useful as a fallback, but provider-reported capabilities and runtime state should be preferred where available.

Vehicle capabilities can differ by:

- model year;
- configuration;
- region;
- account;
- software version; and
- provider policy.

### Preserve reverse-engineering findings in this ADR

Rejected.

The investigative details used to understand undocumented provider behaviour are not necessary to explain the architectural decision.

Keeping those details in a public ADR increases maintenance burden, exposes implementation-specific provider information unnecessarily, and makes the document harder to understand.

## Documentation Requirements

Public documentation should describe remote functionality from the user's perspective.

Prefer:

> Remote controls vary by vehicle, provider, model, market, and currently available capabilities.

Avoid making broad claims that every displayed or implemented command is available on every vehicle.

Detailed capability documentation should distinguish between:

- supported by provider;
- implemented;
- validated;
- exposed in Hisingen; and
- currently available.

## Decision Summary

Remote-command implementations that meet Hisingen's production threshold are compiled into normal builds.

Whether a command is available is determined at runtime using provider, vehicle, authorization, capability, safety, and application-policy checks.

Experimental or insufficiently validated functionality remains inaccessible until it meets the required production threshold.
