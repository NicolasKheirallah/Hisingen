# Logging & Diagnostics

How Hisingen logs, what is kept where, and how the diagnostic bundle export works.

## Unified logging (os.Logger)

All unified-log output goes through one subsystem and one factory:

- Subsystem: `io.kheirallah.hisingen`, defined exactly once in `Support/AppLog.swift`.
- Every logger is created with `AppLog.logger("category")` — never `Logger(subsystem:)`
  directly. The diagnostic bundle filters the log store on this exact string, so a
  drifted literal would silently drop that file's entries from exports.
  `DiagnosticSourceGuardrailTests` enforces this at CI time.

### Categories

| Category | Owner |
|---|---|
| `application` | `AppDelegate` lifecycle, sign-in flows, launch-at-login |
| `refresh` | `RefreshCoordinator` polling loop, live stream reconnects |
| `commands` | `CommandCoordinator` remote-command pipeline |
| `polestar-api` | `PolestarAPI` (REST/GraphQL) |
| `volvo-api` | `VolvoAPI` |
| `database` | `VehicleDatabase` |
| `sqlite` | low-level `SQLiteDatabase` |
| `state-store` | persisted vehicle snapshots |
| `keychain` | credential storage |
| `image-cache` | vehicle image CDN cache (not recorded in the API store — see below) |
| `geocoder` | reverse geocoding (Apple services; no request metadata exists to record) |
| `spotlight` | Spotlight publication |
| `updates` | update checks (recorded as provider `.hisingen`) |

### Level policy

- `.debug` — internal state transitions; safe to lose.
- `.info` — notable successful operations (command sent, session restored).
- `.warning` — degraded-but-recovered paths (stream drops, discovery degradation).
- `.error` — operation failed; carries `String(describing: error)` so enum payloads
  (`server(statusCode: 503)`) and NSError codes survive. `localizedDescription` is
  reserved for user-facing strings.
- `.fault` — unrecoverable degradation (database open/schema failure) where the app
  keeps running but a subsystem is effectively dead.

### Privacy rules

1. Every interpolation carries an explicit `privacy:` annotation.
2. Server-supplied strings (GraphQL error summaries, provider error descriptions) are
   passed through `DiagnosticRedaction.redact(_:)` *before* being logged `.public`.
3. `DiagnosticRedaction` replaces VIN-shaped tokens (17 alphanumerics containing ≥ 2
   digits — the digit requirement keeps ordinary 17-letter words intact), UUID-shaped
   identifiers, and credential-bearing substrings (`token=…`, `Bearer …`).

## API diagnostic store

`Services/Persistence/APIDiagnosticLog.swift` — an actor holding redacted request
metadata for every vehicle-API call plus update checks:

- Recorded by both HTTP transports and the gRPC layer. gRPC records include
  `grpc-status` / percent-decoded `grpc-message` in the operation label, plus response
  byte counts and payload when a frame arrived.
- Redaction happens **at record time**: URLs lose query/fragment, payloads are parsed
  and scrubbed structurally (sensitive keys, coordinates, URLs, identifiers), free-text
  fields pass `DiagnosticRedaction`.
- Retention: newest 2,000 entries **and** a 24-hour window, whichever trims first —
  matching the export lookback. A cumulative payload budget (32 MB) drops oldest
  payload bodies first so the archive stays bounded; metadata rows always survive.
- Persistence: the `shared` instance persists redacted entries to
  `Application Support/Hisingen/api-diagnostics.json` (debounced writes, so at most
  a few seconds of records are lost on a forced quit), meaning a crash or relaunch
  no longer wipes the evidence. Directly-initialized instances (tests) are
  memory-only and hermetic.
- `errorType` captures type name + description + codes, truncated to 300 chars.
- Entry timestamps are request **start** times for unified-log correlation.

## Command audit trail

Remote commands are recorded to SQLite (`remote_commands_log`, pruned after a year)
with outcome, duration, and error text. This is the durable record; the unified log is
the narrative around it.

## Refresh diagnostics

`DiagnosticsSnapshot` (published after nearly every refresh-state transition) now also
carries since-launch counters (`refreshAttempts/Successes/Failures`) — the first fork
in most "data stopped updating" investigations: never worked vs stopped working. The
latest snapshot is mirrored into `LatestDiagnosticsStore` for the exporter.

Refresh network round trips are wrapped in `os_signpost` intervals
(`OSSignposter`, category `refresh`) — visible in Instruments' os_signpost tool with
zero log volume.

## Diagnostic bundle export

Settings → SQLite Storage & Data → **Export Diagnostic Logs**
(`Support/DiagnosticLogExporter.swift`) assembles one JSON file:

| Section | Contents |
|---|---|
| `schemaVersion` | `1`; bump when any section's shape changes |
| `meta` | app version/build, macOS version, hardware model, locale/timezone, redaction note |
| `unifiedLog` | last 24 h of this process's entries under our subsystem (max 4,000), oldest first |
| `apiRequests` | full redacted store entries incl. status/duration/payload (8 MB payload budget, oldest payloads dropped first, `apiPayloadsTruncated` flag) |
| `refreshDiagnostics` | latest snapshot incl. counters |
| `commandAudit` | 25 most recent remote-command audits across vehicles |
| `databaseStats` | table row counts and database size |

Redaction runs again at assembly time regardless of how inputs were constructed.
Only this process's log entries are ever read.

## Capturing logs manually

```sh
log show --predicate 'subsystem == "io.kheirallah.hisingen"' --last 24h
```

or Console.app → search the subsystem. Prefer the in-app export: it adds metadata,
API history, and counters users can't extract themselves.

## Guardrails

- `DiagnosticSourceGuardrailTests`: fails if any source file instantiates
  `Logger(subsystem:)` directly instead of using `AppLog.logger(_:)`.
- `APIDiagnosticLogTests` pins redaction, retention, timestamp, and error-fidelity
  behavior of the store.
- `DiagnosticLogExporterTests` pins bundle schema, section presence/absence, VIN
  heuristic precision, payload budgeting, and collector bounds/ordering.
