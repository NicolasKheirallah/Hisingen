# Polestar gRPC trailers

The production `PolestarHTTP2Transport` uses gRPC Swift 2 and its SwiftNIO HTTP/2 transport. It passes raw protobuf bytes to the existing hand-written Polestar codecs and exposes headers, messages, and final status through `PolestarGRPCTransport`. Unlike the URLSession transport, it can observe HTTP/2 trailers. The URLSession implementation remains available as a trailer-limited transport seam.

Each call creates and closes its own gRPC client and transport. Production connections require TLS; plaintext is restricted to explicitly enabled loopback fixtures. Calls have deadlines and bounded messages. The transport does not automatically replay vehicle commands.

For ordinary unary-style reads, a trailer-capable transport must report a successful final status before the result is accepted. A selected server-streaming read can instead stop deliberately after its first validated snapshot; that is an intentional early stop and does not establish a final status. Continuous live streams consume messages until their final status, cancellation, or interruption.

For commands, a nonzero final status normally overrides a reply. There is one explicit exception: when a payload reply arrives before deadline-exceeded status 4, the reply reaches the command parser and the deadline remains in diagnostics. This is a delivery result, not proof that the vehicle performed the action; telemetry supplies confirmation. Missing or interrupted outcomes remain unknown and are not automatically retried.

Local HTTP/2 tests exercise framing, status, trailers, cancellation, and the exception above. Eight location/weather fixtures distinguish six synthetic vectors from two sanitized owner-capture layouts.

With explicit owner permission on 2026-10-31, an isolated sign-in verified a Polestar 2 model year 2023 and read latest battery, last-known location, and weather through the production TLS transport. All three returned final gRPC status 0. The location response contained redundant outer and nested coordinates; the decoder accepts them only when they match and uses the nested Timestamp. Fixtures preserve the verified layouts with synthetic readings and no vehicle or account identifiers. No vehicle commands were sent. P3 and P4 owner captures remain missing.

Verification passed: 1,739 non-live tests in 223 suites; the Hisingen target builds with compiler warnings treated as errors; dependency notices, localization, decode markers, and coverage source audits pass. Concurrent workspace editing required a private source snapshot for the full suite; all 25 scoped production, test, and fixture files were re-hashed against the workspace afterward and matched. Exact dependency constraints keep the selected graph within Swift 6.0 manifest requirements; SwiftPM emits unused-direct-dependency warnings for these compatibility constraints.

Delivery gate: PASS. Behavior claims are backed by local integration tests, sanitized replay fixtures, and the bounded owner-authorized live check; missing models remain explicit.
