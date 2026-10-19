# Errors and Rate Limits

## Shared error type

Both `PolestarError` and `VolvoError` are provider-specific `Error, LocalizedError` enums; each has an `asVehicleServiceError` bridge into the one type everything above the provider layer actually handles: `VehicleServiceError` (`Services/API/VehicleServiceError.swift`), tagged with `provider: VehicleBrand`. This is the boundary described in [architecture/providers.md](../architecture/providers.md): `RefreshCoordinator`, `AppDelegate`, and the UI only ever see `VehicleServiceError`.

## HTTP status mapping (both providers, same shape)

| Status | Polestar | Volvo |
|---|---|---|
| 2xx | success | success |
| 401 | `.authenticationRequired(.expiredSession)` | `.authenticationRequired(.expiredSession)` (or `.appNotConfigured` if the body mentions the VCC API key) |
| 403 | `.permissionDenied`, or `.authenticationRequired` for specific calls that pass `forbiddenIsAuthentication: true` | `.permissionDenied` for discovery/commands; `.regionRestricted` for per-vehicle telemetry GETs (see below) |
| 429 | `.rateLimited(retryAfter:)`: `Retry-After` header actually parsed | `.rateLimited(retryAfter: nil)`: `Retry-After` header **never parsed**, always `nil` |
| 5xx | `.server(statusCode:)` | `.server(statusCode:)` |
| other 4xx | `.client(statusCode:)` | `.client(statusCode:)` |

**`Retry-After` parsing (Polestar only):** `retryAfter(from:)` handles both raw-seconds (`Retry-After: 30`) and HTTP-date (`Retry-After: Wed, 21 Oct 2026 07:28:00 GMT`) formats, converting the latter to a relative interval. Volvo's `httpFailure` is always called with `retryAfter: nil` at every call site: a real gap, not a deliberate simplification; see

## Volvo's `regionRestricted` heuristic

Volvo's generic `get<T>` REST helper treats a 403 specifically on a **per-vehicle telemetry** GET (energy, connected-vehicle, location endpoints) as `VolvoError.regionRestricted(service:)`: the working assumption is that a 403 there means "this optional service isn't enabled for this vehicle/market," not "wrong OAuth scope." The same 403 on vehicle discovery or a remote command is *not* reinterpreted this way; it stays `.permissionDenied`. This asymmetry isn't explained by any Volvo documentation referenced in the code; it's an empirical judgment call, worth treating as a hypothesis rather than a fact when debugging a real 403.

## gRPC status mapping (Polestar only)

Polestar's gRPC calls carry a `grpc-status` response header rather than relying purely on HTTP status:

- `"0"`: success.
- `"12"` (`UNIMPLEMENTED`): on a read RPC `.grpcUnimplemented(service:)`, which is also remembered per path so the same read is skipped next time; on a write RPC `RemoteCommandError.unsupported`.
- `"14"` (`UNAVAILABLE`): `.grpcUnavailable(service:)`, except when the message is the gateway's `authorization failed`: that is a stable per-service authorization gap rather than an outage, so it becomes `.permissionDenied(operation:)`.
- `"16"` (`UNAUTHENTICATED`) on a **write** RPC: `RemoteCommandError.rejected("Polestar cloud backend requires official mobile app pairing for remote commands.")`.
- `"16"` on a **read** RPC whose message is `Access denied`: `.permissionDenied(operation:)`. PCCS checks authorization before it resolves a method (see `docs/api/polestar-backend-map.md`), so this message reports that the client is not on that service's allowlist rather than that the bearer token is stale, and sibling RPCs succeed with the same token. The rule keys on the message and not on the host, because the same chronos services are published through both the PCCS host and the C3 gateway.
- `"16"` on a read RPC with any other message: `.authenticationRequired(.expiredSession)`.
- Any other non-zero status: generic `.invalidResponse(operation: "gRPC ... status \(status)")`.
- A 401/403 **HTTP** status on the gRPC call itself (before even inspecting `grpc-status`) short-circuits directly to `.authenticationRequired(.expiredSession)`.
- A timed-out streaming read that already received at least one frame is treated as a complete response, not a failure: an empirical workaround for the backend not always closing the HTTP/2 stream cleanly.

## Transient vs. permanent

`isTransient` (both `PolestarError` and `VolvoError`, and the bridged `VehicleServiceError`) is `true` for `.network`, `.rateLimited`, `.server`, and the provider-specific "temporarily unavailable" case (`.grpcUnavailable` / `.temporarilyUnavailable`): these drive `RefreshCoordinator`'s retry/backoff (see [architecture/refresh-system.md](../architecture/refresh-system.md)). Everything else (auth failures, decode failures, permission errors, unsupported-capability errors) is treated as not worth blindly retrying; auth failures surface to the user, decode/permission/unsupported failures degrade that one field via the optional-capability wrapper (see [architecture/capabilities.md](../architecture/capabilities.md)) rather than failing the whole refresh.

## Rate limiting and backoff: two layers

1. **Session-wide** (`RefreshCoordinator`): a `.rateLimited` error sets `rateLimitedUntil`, blocking *any* further refresh (manual or timer) until that time passes. See [architecture/refresh-system.md](../architecture/refresh-system.md#retry-backoff).
2. **Per-capability/per-endpoint** (inside each provider actor): a failure on one optional field sets a cooldown scoped to just that field, so one broken endpoint doesn't block the rest of the refresh. See [architecture/capabilities.md](../architecture/capabilities.md#positive-result-caching-and-negative-result-backoff).

`.authenticationRequired` and `.rateLimited` are explicitly exempted from the per-capability backoff in both providers; they're treated as session-wide problems and propagate immediately rather than being absorbed into one field's cooldown. A service-scoped authorization refusal is deliberately **not** in that set: the `Access denied` and `authorization failed` cases above arrive as `.permissionDenied`, so they take the normal per-capability cooldown and leave the session standing. That split is what keeps one charging read the account is not entitled to from presenting as "Sign In is required." and spending a refresh-token grant on every retry.

## Where errors surface

```
Transport (URLError / HTTP status / grpc-status)
        │
        ▼
Provider error type (PolestarError / VolvoError)
        │  httpFailure(...) / grpc-status inspection
        ▼
VehicleServiceError (via asVehicleServiceError)
        │
        ▼
RefreshCoordinator: classifies via isTransient / requiresAuthentication,
                     schedules retry or surfaces via onError
        │
        ▼
AppDelegate.lastError, sessionValid
        │
        ▼
UI: attentionCard (VehicleTabView), WelcomeSignInView error banner,
     Settings support badges (capability-level "why is this greyed out")
```

Decode failures (`.decoding`, `.invalidResponse`) never reach the UI as a raw error string for an *optional* field; they're absorbed by the capability wrapper and recorded in `unavailableFeatures`/`dataWarnings` instead. They do surface directly for calls with no fallback (e.g. the initial vehicle-discovery query), where a decode failure means there's genuinely nothing to show yet.
