# ADR-0008: Hand-written Polestar protobuf codecs

Status: Accepted

## Context

Polestar's newer vehicle-data API (referred to internally as C3/PCCS-Chronos)
is gRPC-based and undocumented; Polestar publishes no official `.proto`
schema for it. The package includes Sparkle for application updates; the vehicle
wire decoder does not currently require a protobuf package or code generator.

## Decision

Implement the specific protobuf message encoding and parsing
Hisingen needs by hand (`Services/API/PolestarWire.swift`,
`PolestarGRPCCapabilities.swift`, and `PolestarGRPCRemote.swift`)
rather than adding the `SwiftProtobuf` package and a
`protoc` code-generation step.

## Alternatives considered

- **`SwiftProtobuf` + `protoc`-generated Swift**: would mean less
  hand-written parsing code, but Polestar doesn't publish an official
  `.proto` schema, so the "generated" code would still be generated from an
  unofficial schema, and it adds a build-time code-gen step plus an
  dependency to the vehicle protocol implementation. The lack of an official
  schema means code generation alone would not establish field semantics.

## Consequences

No additional protobuf dependency resolution or code generation is required.
The decoder validates field bounds, varint overflow, complete wire messages,
and known nested message schemas while retaining unknown fields for inspection.
`PolestarGRPCTransport` separates network I/O from service and wire parsing.
The default `PolestarHTTP2Transport` uses the maintained gRPC Swift 2 and NIO
HTTP/2 transport to observe final gRPC status and trailers. It creates and
closes a client for each call; it does not automatically replay commands.
The URLSession implementation remains available as a trailer-limited seam.

Ordinary reads require final status when the transport supports it. Selected
server-streaming reads intentionally stop after the first validated snapshot.
A command reply followed by deadline status 4 can be delivered to the command
parser, with the deadline retained in diagnostics; telemetry still establishes
physical confirmation. Other nonzero final statuses override a reply. Missing
or interrupted command outcomes remain unknown and are not automatically retried.
See [the transport record](../architecture/polestar-trailers-2026-10-31.md).

Any change to Polestar's wire format
requires manually updating the hand-rolled parser rather than regenerating
from an updated `.proto` file, and the parsing code itself needs to earn its
own test coverage that a generated-code approach would get for free; see
[api/polestar.md](../api/polestar.md).
