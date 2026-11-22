# Logging & Diagnostics

How Hisingen logs, what is kept where per vehicle, and how the diagnostic bundle export
works.

## System log (os.Logger)

All unified-log output goes through one subsystem and one factory:

- Subsystem: `io.kheirallah.hisingen`, defined exactly once in `Support/AppLog.swift`.
- Every logger is created with `AppLog.logger("category")`, never `Logger(subsystem:)`
  directly. The diagnostic bundle filters the log store on this exact string, so a
  drifted literal would silently drop that file's entries from exports.
  `DiagnosticSourceGuardrailTests` enforces this at CI time.

A vehicle is **not** a subsystem or a category. Apple's model defines a subsystem as a
large functional area and a category as an area within it; neither has a structured
per-entity dimension. A category per VIN would break the bundle's one-predicate query,
crowd every Console filter, and still have no place for account-level traffic. The system
log therefore stays one stream, and per-vehicle narrative lives in the API diagnostic log
below. [ADR-0013](../adr/0013-per-vehicle-diagnostic-log.md) records the alternative that
was rejected.

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
| `image-cache` | vehicle image CDN cache (not recorded in the API store; see below) |
| `geocoder` | reverse geocoding (Apple services; no request metadata exists to record) |
| `spotlight` | Spotlight publication |
| `updates` | update checks (recorded as provider `.hisingen`) |

### Level policy

- `.debug`: internal state transitions; safe to lose.
- `.info`: notable successful operations (command sent, session restored).
- `.warning`: degraded-but-recovered paths (stream drops, discovery degradation).
- `.error`: operation failed; carries `String(describing: error)` so enum payloads
  (`server(statusCode: 503)`) and NSError codes survive. `localizedDescription` is
  reserved for user-facing strings.
- `.fault`: unrecoverable degradation (database open/schema failure) where the app
  keeps running but a subsystem is effectively dead.

### Privacy rules

1. Every interpolation carries an explicit `privacy:` annotation.
2. Server-supplied strings (GraphQL error summaries, provider error descriptions) are
   passed through `DiagnosticRedaction.redact(_:)` *before* being logged `.public`.
3. `DiagnosticRedaction` replaces VIN-shaped tokens (17 alphanumerics containing ≥ 2
   digits; the digit requirement keeps ordinary 17-letter words intact), UUID-shaped
   identifiers, and credential-bearing substrings (`token=…`, `Bearer …`).

## API diagnostic log

`Services/Persistence/APIDiagnosticLog.swift`: an actor holding redacted request
metadata for every vehicle-API call plus update checks. It is **partitioned per vehicle**:
one ring for each car, one for account-level traffic, one for rows written before the
partition existed.

### Declaring the scope

`VehicleLogScope` is a required parameter at both transport seams,
`HTTPExchange.data(for:using:limit:operation:provider:scope:…)` and the gRPC
`recordExchange(…, vin:, …)`:

- `.vehicle(vin)` for anything fetched for, or sent to, one car.
- `.account` for token grants, sign-in windows, vehicle discovery, account verification,
  OIDC discovery, C3 host discovery, and update checks.

The compiler forces the decision. A new call site cannot omit its log, and account-level
code cannot inherit a vehicle log by omission. `SignInCoordinator` and the command sign-in
presenter record their traces with `.account`.

### Partition identity

`APILogPartitionKey` is `account`, `legacy`, or `vehicle-` plus 64 bits of SHA-256 over
the normalized VIN (`Support/VIN.swift`). The digest is unsalted so the archive survives
relaunches, and it cannot be reversed to a VIN. Partition keys, not VINs, are what the
archive and the support export name parts of the log by.

### Retention and budgets

| Scope | Rows | Payload bodies | Age |
|---|---|---|---|
| One partition | 10,000 | 8 MB | 24 h |
| Whole archive | 30,000 | 32 MB | 24 h |
| Partitions | 16, least recently active retired first | | |

A partition trims its own count, age and payload budget, so a busy car cannot evict
another car's rows. The fleet ceilings then bound the archive: oldest rows first, oldest
payload bodies first. Payload bytes are tracked incrementally, so a record does not rescan
every retained body.

### Persistence and migration

The `shared` instance persists redacted entries to
`Application Support/Hisingen/api-diagnostics.json` with debounced atomic writes (at most
a few seconds of records are lost on a forced quit). The file is
`{ "version": 2, "partitions": { "<key>": [entries] } }`.

The previous single-array format decodes into the `legacy` partition. Those rows carry no
vehicle, so they are not assigned to a car by guesswork; the 24-hour window retires them.
Directly initialized instances (tests) are memory-only and accept a temporary archive URL.

### Inspector and clearing

Settings → SQLite Storage & Data → **Inspect Live API Log** opens
`UI/Settings/APIDiagnosticInspectorView.swift`, a live read-only view over the sanitized
store. It opens on the active car and offers:

- the garage in its configured order, plus `All`, `Account`, and `Unknown` (legacy rows);
- the provider, outcome and free-text filters over the selected log only;
- a scoped Clear: the selected vehicle's entries, or every partition when `All` is shown.

A garage car with no rows is listed and reads "No API requests recorded", which answers
"did this car call anything?" without opening a file. A signed-out car whose log outlived
its session appears as `Vehicle 4F2A`, its opaque key prefix.

### Erase integration

`LocalDataEraser` erases the matching log partition on `.everything` (the deliberate
"Erase local data" action, and "erase history on sign out" when enabled). A plain sign-out
keeps the log: it is the evidence for why the session ended, it is already redacted, and
the 24-hour window retires it. `eraseVehicleLogsSynchronously(vin:)` bridges the actor onto
the synchronous erase path with a bounded wait; the fleet-wide form is
`eraseAllLogsSynchronously()`.

## Command audit trail

Remote commands are recorded to SQLite (`remote_commands_log`, pruned after a year)
with outcome, duration, and error text. This is the durable record; the diagnostic log is
the narrative around it.

## Refresh diagnostics

`DiagnosticsSnapshot` (published after nearly every refresh-state transition) now also
carries since-launch counters (`refreshAttempts/Successes/Failures`); the first fork
in most "data stopped updating" investigations: never worked vs stopped working. The
latest snapshot is mirrored into `LatestDiagnosticsStore` for the exporter.

Refresh network round trips are wrapped in `os_signpost` intervals
(`OSSignposter`, category `refresh`), visible in Instruments' os_signpost tool with
zero log volume.

## Diagnostic bundle export

Settings → SQLite Storage & Data → **Export Diagnostic Logs**
(`Support/DiagnosticLogExporter.swift`) assembles one JSON file:

| Section | Contents |
|---|---|
| `schemaVersion` | `5`; bump when any section's shape changes |
| `meta` | app version/build, macOS version, hardware model, locale/timezone, redaction and partition notes |
| `unifiedLog` | last 24 h of this process's entries under our subsystem (max 4,000), oldest first |
| `apiRequests` | object keyed by partition (`account`, `legacy`, `vehicle-<digest>`), each an oldest-first list of redacted entries incl. status/duration/payload (8 MB payload budget shared newest-first, `apiPayloadsTruncated` flag) |
| `apiRequestPartitions` | one row per partition: id, request count, first/last request time |
| `refreshDiagnostics` | latest snapshot incl. counters and command-confirmation lifecycle |
| `polestarVDMS` | active VDMS discovery backoff deadline and failure category, when applicable |
| `commandAudit` | 25 most recent remote-command audits across vehicles |
| `databaseStats` | table row counts and database size |

Redaction runs again at assembly time regardless of how inputs were constructed.
Only this process's log entries are ever read. A bundle cannot be turned back into a VIN:
the per-vehicle keys are digests, and VIN-shaped text inside a row is still replaced with
`<vehicle>`.

## Capturing logs manually

```sh
log show --predicate 'subsystem == "io.kheirallah.hisingen"' --last 24h
```

or Console.app → search the subsystem. The system log is one stream; for a per-car record,
use the in-app inspector or the bundle's `apiRequests` partitions. Prefer the in-app
export: it adds metadata, API history, and counters users can't extract themselves.

## Guardrails

- `DiagnosticSourceGuardrailTests`: fails if any source file instantiates
  `Logger(subsystem:)` directly instead of using `AppLog.logger(_:)`.
- `APIDiagnosticLogTests`: pins redaction, retention, timestamp, and error-fidelity
  behavior of the store.
- `APIDiagnosticPartitionTests`: pins per-vehicle filing, opaque keys, per-partition and
  fleet budgets, archive migration, the synchronous erase forms, and scope attribution at
  the HTTP seam.
- `DiagnosticLogExporterTests`: pins bundle schema, section presence/absence, VIN
  heuristic precision, payload budgeting across partitions, and collector
  bounds/ordering.
- `APIDiagnosticInspectorRowsTests`: pins row identity, search, and the merged versus
  per-vehicle selection.
