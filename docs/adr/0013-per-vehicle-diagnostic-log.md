# ADR-0013: One diagnostic log per vehicle, one system log

Status: Accepted

## Context

A single Polestar or Volvo account can hold more than one vehicle, and the rest of the
app was already VIN-scoped ([0007](0007-vin-scoped-state.md)). The API diagnostic log was
not. One ring buffer, one Settings inspector and one support bundle mixed every car's
requests together, so a busy vehicle could evict another vehicle's rows, the inspector
could not answer "what did this car do", and a bundle gave support no way to separate the
cars.

"Unified log" also names Apple's system logging facility. Its model defines a subsystem as
a large functional area and a category as an area within that subsystem. It has no
structured per-entity field and no API for a dynamic set of categories.

Every request already passes exactly two seams: `HTTPExchange.data` for HTTP and
`recordExchange` for gRPC. That is where attribution can be declared.

## Decision

1. Keep one os.Logger subsystem and its static category set. A vehicle is request data,
   not a logging category or a subsystem. The system log stays one stream that Console and
   the bundle can query with one predicate.
2. Partition the app-owned API diagnostic log by vehicle. `VehicleLogScope` is a required
   parameter at both transport seams: a caller passes `.vehicle(vin)` or says `.account`
   out loud. The compiler, not a convention, decides whether a new call site has declared
   its log.
3. Partition identity is opaque: `vehicle-` plus 64 bits of SHA-256 over the normalized
   VIN, the same digest scheme as the Spotlight identifier. The archive and every export
   carry the digest, never the VIN.
4. Retention and budgets are per partition (24 hours, 10,000 rows, 8 MB of payload bodies)
   with fleet ceilings (30,000 rows, 32 MB, 16 partitions). Each car keeps its own
   evidence; the archive stays bounded.
5. The archive is versioned JSON: `{ "version": 2, "partitions": { ... } }`. The previous
   single-array file loads into a `legacy` partition instead of being assigned to a car by
   guesswork.
6. The inspector gains a vehicle picker (every garage car, All, Account, Unknown), opens on
   the active car, and its clear action clears only what is shown. The bundle groups
   `apiRequests` by partition and adds `apiRequestPartitions` with counts and windows
   (`schemaVersion` 5).
7. Erasing a vehicle's local data erases its log partition. A plain sign-out keeps it: the
   log is the evidence for why the session ended, it is redacted, and the 24-hour window
   retires it without help.

## Alternatives considered

- **A subsystem or category per VIN.** Rejected. It breaks the bundle's single-predicate
  query, dims every Console filter, multiplies the log store's indexes for a value that is
  data, and still has no place for the account partition.
- **Reading the vehicle out of the request URL.** Rejected. Vehicle identifiers also
  appear in bodies and headers, the URL is redacted on purpose, and a heuristic that
  misses would file one car's request under another.
- **Ambient task-local scope.** Rejected as the primary mechanism. It is invisible, the
  compiler cannot check it, and account-level calls made inside a vehicle fetch (token
  renewal, for one) would inherit the wrong log unless every one of them opted out.
- **One disk file per partition.** Rejected for now. It fixes write amplification but adds
  file lifecycle, cleanup and orphan handling; per-partition bounds already isolate
  retention, and the single archive can be split later without changing the model.
- **A SQLite table beside the vehicle database.** Rejected. The diagnostic archive is a
  redacted, bounded support artifact with its own retention, not vehicle history; moving
  it would add write contention on the refresh path for no gain over partitioned JSON.

## Consequences

- Two cars can no longer evict each other's evidence, and a support bundle can be read per
  car. Partition ids are stable across exports, so two bundles can be compared.
- Every new network seam has to declare a scope, and account-level code says `.account`.
  That is a small compile-time cost that replaces a silent misattribution.
- The archive file is a new format with one migration path from the old array.
- The system unified log is still one stream, by design. Per-car narrative lives in the
  inspector and `apiRequests`; the bundle's `unifiedLog` section correlates by timestamp.
