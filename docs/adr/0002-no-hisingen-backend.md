# ADR-0002: Direct vehicle-cloud integration, no Hisingen-operated backend

Status: Accepted

## Context

Hisingen needs to authenticate against and query Polestar's and Volvo's own
cloud APIs. A common architecture for this kind of integration is a
developer-operated backend that holds credentials/tokens, calls the vendor
API, and serves a simplified response to the client app.

## Decision

Hisingen has no backend of its own. `PolestarAPI` and `VolvoAPI` run entirely
on the user's Mac and call Polestar's / Volvo's cloud services directly,
using credentials the user supplies and that never leave the device except
to the vendor's own servers.

## Alternatives considered

- **Hisingen-operated backend/proxy** — would let the client stay simpler and
  allow server-side caching, but makes Hisingen a new custodian of vehicle
  credentials and tokens for every user, creates an ongoing hosting cost and
  availability dependency, and turns a single-developer open-source project
  into an operator of infrastructure that handles other people's vehicle
  access credentials.

## Consequences

No server-side attack surface, no hosting cost, and no outage dependency for
Hisingen as a project. Credentials and vehicle data are exposed only to the
vendor whose account they belong to and to the user's own machine — see
[security/threat-model.md](../security/threat-model.md). The tradeoff: any
change to a vendor's undocumented auth flow or API shape (Polestar in
particular — see [api/polestar.md](../api/polestar.md)) requires an app
update rather than a server-side fix, and there is no server-side
cross-device sync or aggregation.
