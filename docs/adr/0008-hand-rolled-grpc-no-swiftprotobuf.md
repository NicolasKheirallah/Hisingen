# ADR-0008: Hand-rolled gRPC/protobuf engine instead of SwiftProtobuf

Status: Accepted

## Context

Polestar's newer vehicle-data API (referred to internally as C3/PCCS-Chronos)
is gRPC-based and undocumented — Polestar publishes no official `.proto`
schema for it. `Package.swift` otherwise declares zero external SwiftPM
dependencies: no `.package()` entries and no `Package.resolved`.

## Decision

Implement wire-level gRPC framing and the specific protobuf message parsing
Hisingen needs by hand — `Services/API/PolestarGRPC.swift`,
`PolestarGRPCCapabilities.swift`, and `PolestarGRPCRemote.swift` (roughly
1,500 lines combined) — rather than adding the `SwiftProtobuf` package and a
`protoc` code-generation step.

## Alternatives considered

- **`SwiftProtobuf` + `protoc`-generated Swift** — would mean less
  hand-written parsing code, but Polestar doesn't publish an official
  `.proto` schema, so the "generated" code would still be generated from a
  reverse-engineered schema — and it adds a build-time code-gen step plus an
  external dependency to a project that's otherwise intentionally
  dependency-free (see [0002](0002-no-hisingen-backend.md) for the same
  minimal-footprint instinct applied to infrastructure).

## Consequences

No SwiftPM dependency resolution and no supply-chain surface from a
third-party protobuf library — `dependency-review.yml` has
nothing from this to flag today. Full control over exactly which message
fields are parsed. The tradeoff: any change to Polestar's wire format
requires manually updating the hand-rolled parser rather than regenerating
from an updated `.proto` file, and the parsing code itself needs to earn its
own test coverage that a generated-code approach would get for free — see
[api/polestar.md](../api/polestar.md) and
[testing/fixtures.md](../testing/fixtures.md).
