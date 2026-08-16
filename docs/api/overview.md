# API Overview

Every remote service Hisingen talks to, in one table. Detail for each provider lives in [polestar.md](polestar.md) and [volvo.md](volvo.md); authentication mechanics live in [authentication.md](authentication.md); error/rate-limit handling lives in [errors-and-rate-limits.md](errors-and-rate-limits.md).

## Inventory

| Provider | Service | Host | Protocol | Auth | Purpose |
|---|---|---|---|---|---|
| Polestar | Polestar ID (OIDC) | `polestarid.eu.polestar.com` | HTTPS, scraped PingFederate login flow | PKCE (app-internal implementation) | Login, token refresh |
| Polestar | GraphQL — authenticated | `pc-api.polestar.com/eu-north-1/mystar-v2/` | GraphQL over HTTPS | Bearer token | Coarse telemetry (`CarTelematicsV2`), legacy vehicle discovery (`GetConsumerCarsV2`) |
| Polestar | GraphQL — app-backend / VDMS | `pc-api.polestar.com/eu-north-1/app-backend/api/graphql` | GraphQL over HTTPS | `X-PolestarId-Authorization: Bearer` (non-standard header) | Primary vehicle discovery (`GetVDMSCars`) |
| Polestar | GraphQL — public | `pc-api.polestar.com/eu-north-1/mystar-public/` | GraphQL over HTTPS | `x-api-key` (AppSync-style, no bearer token) | Studio vehicle images (`GetCarImages`) |
| Polestar | C3 discovery | `cnepmob.volvocars.com` | HTTPS/JSON | Bearer token | Resolves the actual C3 gRPC host/port |
| Polestar | C3 backend | discovered host (via above) | Hand-rolled gRPC-over-HTTP/2 | Bearer token | Exterior, health/tyres, odometer, dashboard, OTA/software, schedules, location, parking climate, pre-cleaning, weather fallback |
| Polestar | PCCS / Chronos | `api.pccs-prod.plstr.io:443` | Hand-rolled gRPC-over-HTTP/2 | Bearer token | Target SOC, amp limit, global/location charge schedules, climate timers, charge-now override, remote command invocation |
| Volvo | Volvo ID (OAuth2) | `volvoid.eu.volvocars.com` | HTTPS, `/as/authorization.oauth2` + `/as/token.oauth2` | OAuth2 PKCE | Login, token refresh |
| Volvo | Connected Vehicle API v2 / Energy API v2 / Location API v1 | `api.volvocars.com` | REST/JSON over HTTPS | Bearer token + `vcc-api-key` header | All Volvo telemetry, vehicle discovery, remote commands |
| Both | Vehicle images | Provider-specific, above | HTTPS | Bearer or `x-api-key` | Studio render download |
| — | Apple CoreLocation (`CLGeocoder`) | Apple-operated | System framework | N/A | Reverse geocoding, opt-in |
| — | Open-Meteo | `api.open-meteo.com` | REST/JSON | None | Weather at vehicle location, opt-in |
| — | GitHub Releases API | `api.github.com/repos/NicolasKheirallah/hisingen` | REST/JSON | None | Update checks, opt-in |
| — | GitHub Pages | `nicolaskheirallah.github.io/Hisingen/oauth-callback.html` | Static HTML/JS | N/A | Bridges Volvo's `http(s)`-only redirect requirement to Hisingen's `hisingen://` URL scheme |

## API confidence

Hisingen's own README puts it plainly: *"Polestar does not publish a supported third-party vehicle-cloud API."* This matters enough to rate explicitly, per capability family, rather than treat "Polestar" and "Volvo" as equally solid ground.

| Category | Confidence | Basis |
|---|---|---|
| Volvo Connected Vehicle API v2 / Energy API v2 / Location API v1 | **Official** | Documented at developer.volvocars.com; requires a registered Developer Portal application (Client ID, Client Secret, VCC API Key) |
| Volvo OAuth2/PKCE flow, token endpoint shape | **Official** | Standard OAuth2 against a documented Volvo ID authorization server |
| Volvo response envelope shape (`{"data": ...}` vs. bare root, wrapped vs. bare scalar fields) | **Strongly inferred** | Code defensively decodes both shapes (`VolvoEnvelope`, `VolvoField`) — observed to vary across endpoints/versions, not asserted as stable by Volvo's docs |
| Volvo `readScopes` → endpoint mapping | **Strongly inferred** | No in-repo reference to an official scope table; tuned empirically |
| Volvo 403 → region-restricted inference | **Experimental** | A heuristic applied only to per-vehicle telemetry GETs — see [errors-and-rate-limits.md](errors-and-rate-limits.md) |
| Polestar OIDC discovery, PKCE, token exchange | **Strongly inferred** | Standard OIDC shape, reverse-engineered by observing the official web/mobile client's login flow |
| Polestar GraphQL query/field names (`CarTelematicsV2`, `GetVDMSCars`, etc.) | **Strongly inferred** | Not documented by Polestar; reconstructed from observed client traffic; the `apollo-kotlin` client-library headers on `GetVDMSCars` are a deliberate mimicry of the official Android app |
| Polestar gRPC service paths, protobuf field numbers | **Experimental** | Entirely reverse-engineered — no `.proto` schema exists in the repo; every field's meaning is inferred from observed values in code comments (e.g. `case 26:` = power state) |
| Polestar capability/model behavior (per-model support table) | **Community documented** | Built from observed behavior across models, explicitly conservative where unverified (see [domain/capability-matrix.md](../domain/capability-matrix.md)) |
| Polestar OTA dispatch (`ota_mobcache.SchedulerService`) | **Strongly inferred** | Request/response shapes cross-checked against an independent reverse-engineered client; requires the mobile-app OIDC client's `customer:attributes:write` scope. Compiled into all builds since [ADR-0009](../adr/0009-remote-commands-compiled-into-all-builds.md) |
| Polestar non-OTA remote commands (PCCS) | **Experimental / unverified** | Dispatch compiles, but the UI keeps these controls disabled and the PCCS package prefixes are unconfirmed — see [architecture/technical-debt.md](../architecture/technical-debt.md) |
| Volvo remote-command response contract | **Strongly inferred** | Parsed as an untyped JSON dictionary rather than a typed DTO — see [architecture/technical-debt.md](../architecture/technical-debt.md) |

None of the above is presented as an official guarantee anywhere in the app or in this documentation. Where the code makes a reverse-engineered assumption, that assumption is named as such in [polestar.md](polestar.md) and [volvo.md](volvo.md) rather than written up as settled fact.

## Where these live in the source

- `Sources/Hisingen/Services/API/PolestarAPI.swift`, `PolestarGRPC.swift`, `PolestarGRPCCapabilities.swift`, `PolestarGRPCRemote.swift`, `GraphQLModels.swift`, `PolestarServiceError.swift`
- `Sources/Hisingen/Services/API/VolvoAPI.swift`, `VolvoModels.swift`, `VolvoServiceError.swift`
- `Sources/Hisingen/Services/API/VehicleProviding.swift`, `VehicleServiceError.swift`, `HTTPBodyReader.swift`
- `Sources/Hisingen/Services/Location/ReverseGeocoder.swift`, `Services/Updates/UpdateChecker.swift`
