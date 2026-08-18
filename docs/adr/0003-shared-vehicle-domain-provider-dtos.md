# ADR-0003: Shared vehicle domain, provider-specific DTOs kept out of it

Status: Accepted

## Context

Polestar and Volvo expose the vehicle in completely different shapes:
Polestar via GraphQL plus a hand-rolled gRPC channel
([0008](0008-hand-rolled-grpc-no-swiftprotobuf.md)), Volvo via a documented
REST API (Connected Vehicle, Energy, Location). The rest of the app — UI,
notifications, persistence, refresh coordination — needs one consistent
vehicle model to work against, not two.

## Decision

Define brand-agnostic domain types in `Domain/` (`VehicleState`,
`VehicleCapabilities`, `RemoteCommand`) and a single `VehicleProviding`
protocol. `PolestarAPI` and `VolvoAPI` each conform to it, and each owns the
job of mapping its own wire-format DTOs (GraphQL/protobuf response types for
Polestar, REST response models for Volvo) into the shared domain internally.
Wire-format types never cross into `Domain/`, `UI/`, or the persistence/
notification layers.

## Alternatives considered

- **Expose provider DTOs directly to the UI** — less mapping code up front,
  but every UI view, notification rule, and persisted cache would need
  per-brand branching, and adding a third provider would mean touching all
  of them instead of implementing one protocol conformance.

## Consequences

`UI/`, `Services/Persistence/`, `Services/Notifications/`, and
`Services/Refresh/` all operate on one model regardless of which brand is
connected. Adding a third vehicle provider means implementing
`VehicleProviding` once; it does not require changes to UI, persistence, or
notification code. The cost is a mapping layer inside each provider that
must be kept correct as vendor API shapes change — see
[architecture/providers.md](../architecture/providers.md).
