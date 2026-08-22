# Architecture Decision Records

Lightweight ADRs for decisions that genuinely shaped Hisingen's architecture and are worth recording so a future contributor doesn't have to reverse-engineer *why*, not just *what*. Where the original reasoning isn't recoverable from the repository, that's stated explicitly rather than invented.

Format:

```markdown
# ADR-NNNN: Decision title

Status: Accepted

## Context
## Decision
## Alternatives considered
## Consequences
```

## Index

| ADR | Title |
|---|---|
| [0001](0001-native-swift-appkit-swiftui.md) | Native Swift, AppKit + SwiftUI, no cross-platform framework |
| [0002](0002-no-hisingen-backend.md) | Direct vehicle-cloud integration, no Hisingen-operated backend |
| [0003](0003-shared-vehicle-domain-provider-dtos.md) | Shared vehicle domain, provider-specific DTOs kept out of it |
| [0004](0004-keychain-for-credentials.md) | Keychain for renewable credentials, not UserDefaults |
| [0005](0005-read-only-remote-controls-by-default.md) | ~~Read-only by default; remote control gated behind an experimental compile flag~~ (superseded by 0009) |
| [0006](0006-runtime-capability-probing.md) | Runtime capability observation over static model assumptions |
| [0007](0007-vin-scoped-state.md) | VIN-scoped state throughout, not account- or session-scoped |
| [0008](0008-hand-rolled-grpc-no-swiftprotobuf.md) | Hand-rolled gRPC/protobuf engine instead of SwiftProtobuf |
| [0009](0009-remote-commands-compiled-into-all-builds.md) | Remote commands are compiled into all builds (supersedes 0005) |
| [0010](0010-biometric-confirmation-default-off-for-routine-commands.md) | Biometric confirmation defaults off for routine remote commands |
