# Polestar Integration

Hisingen supports Polestar vehicles through vehicle-cloud interfaces used by Polestar's own services.

Polestar does not currently provide a supported public third-party vehicle API for this use case. As a result, the integration is based on observed first-party behaviour and compatibility testing rather than a published API contract.

That distinction matters:

- the integration can change or stop working without notice;
- functionality may differ between models, model years, markets and accounts;
- a successful response on one vehicle does not prove universal support;
- undocumented behaviour is treated conservatively by Hisingen;
- Hisingen does not claim that these interfaces are officially supported by Polestar.

This document deliberately describes the integration at a functional level. Detailed reverse-engineering notes, captured traffic, backend inventories, protocol field maps and probing material are not part of the public repository.

---

## Integration overview

The Polestar integration provides three broad categories of functionality:

1. **Account and vehicle discovery**
   - authentication with the user's Polestar account;
   - discovery of vehicles associated with the account;
   - selection and identification of a vehicle.

2. **Vehicle state**
   - battery and range;
   - charging;
   - doors, windows and locks;
   - vehicle health;
   - climate state;
   - trip and odometer information;
   - software/update information where available;
   - connectivity;
   - location;
   - vehicle imagery.

3. **Vehicle actions**
   - climate;
   - locks and openings;
   - charging configuration;
   - charging and climate schedules;
   - other supported remote actions.

Not every capability is available on every vehicle.

Hisingen therefore separates:

- what the application knows how to request;
- what a particular vehicle is expected to support;
- what the provider actually reports at runtime.

See [Capability Matrix](../domain/capability-matrix.md) and [Capabilities](../architecture/capabilities.md).

---

## Authentication

Polestar authentication is based on the same general identity infrastructure used by Polestar's first-party services.

Hisingen uses an OAuth/OIDC-style authorization flow with PKCE and validates authentication redirects before accepting them.

Authentication credentials are sent directly from Hisingen to Polestar's identity service. Hisingen does not operate an authentication relay or backend.

Long-lived session material is stored in the macOS Keychain. Short-lived access credentials remain in memory where practical.

See:

- [Authentication](authentication.md)
- [Keychain](../security/keychain.md)
- [Security Overview](../security/overview.md)

Because this authentication flow is not a documented third-party integration contract, changes to Polestar's sign-in pages or authentication behaviour can require a Hisingen update.

---

## Vehicle discovery

After authentication, Hisingen discovers the vehicles available to the signed-in account and maps them into the shared `CarSummary` and `VehicleState` domain models.

Vehicle discovery may expose different amounts of information depending on the account and backend response.

Hisingen uses information such as:

- VIN;
- model;
- model year;
- vehicle configuration metadata;
- image-related metadata where available.

A VIN is treated as the stable local identifier for per-vehicle state.

Hisingen also supports conservative handling of vehicles or model variants it does not yet explicitly recognize rather than rejecting them outright.

See [Vehicle Domain Model](../domain/vehicle.md).

---

## Core telemetry

The Polestar integration can obtain the core state needed for the main Hisingen interface, including:

- battery percentage;
- estimated electric range;
- charging state;
- estimated charging completion time;
- vehicle availability;
- model information.

Additional data is requested only when the corresponding Hisingen feature is enabled.

This helps avoid making unnecessary provider requests for features the user has disabled.

---

## Charging

Depending on vehicle and backend availability, Hisingen can display:

- battery state of charge;
- electric range;
- charging status;
- charging connection state;
- AC/DC charging information;
- charging power;
- charging current;
- charging voltage;
- charge target;
- charging current limit;
- estimated time remaining;
- charging schedules;
- departure-related schedules;
- charge-now overrides.

Some charging information comes from different provider services and may have different timestamps.

Hisingen prefers the most appropriate available value rather than assuming every response is equally fresh.

### Charging history

Hisingen can build local charging history from observed vehicle state.

That can include:

- starting and ending state of charge;
- estimated energy added;
- charging duration;
- observed peak power;
- calculation source, confidence, and observation coverage;
- optional price and estimated charging cost.

Power is integrated when observation coverage is sufficiently complete; otherwise the estimate
uses SoC change and usable capacity. Tariff inputs are snapshotted per session. These are still
application-level estimates and should not be treated as certified electricity-meter data.

See [Charging](../domain/charging.md).

---

## Climate

Hisingen can display climate state where reported by the vehicle.

Remote climate behaviour depends strongly on the vehicle generation.

### Polestar 2

The vehicle manages the climate comfort setpoint.

Hisingen should therefore not present a user-selectable cabin temperature as though the vehicle accepts it through the same remote interface.

### Newer Polestar platforms

Some newer vehicles expose richer climate capabilities.

Where verified and permitted by the capability model, Hisingen may expose controls such as:

- cabin temperature;
- seat heating;
- steering-wheel heating;
- climate timers.

These controls are capability-gated and must not be inferred only from the vehicle name.

---

## Doors, windows and locks

Where available, Hisingen can display exterior state including:

- central locking state;
- individual doors;
- windows;
- hood;
- tailgate;
- charge-port door;
- roof/opening state;
- alarm-related state.

Provider responses are sometimes partial.

Hisingen therefore avoids converting a missing field into a false "closed", "locked" or otherwise safe state.

When appropriate, partial responses can be merged with previously known information while preserving freshness information.

---

## Vehicle health

Polestar vehicles can expose varying levels of health and diagnostic information.

Hisingen may display:

- tyre warnings;
- individual tyre pressure where available;
- exterior-light warnings;
- low-voltage battery warnings;
- fluid warnings;
- service information;
- other vehicle warnings.

The application does not fabricate a normal value when the provider does not return one.

A missing pressure, warning state or service field remains unavailable unless another valid source provides it.

---

## Trips and odometer

Where available, Hisingen can display:

- total odometer;
- manual trip information;
- automatic trip information;
- average consumption;
- related driving statistics.

Which fields are available varies by vehicle and backend response.

---

## Connectivity

Some Polestar vehicles expose connectivity information that Hisingen can use to provide additional context about the reported vehicle state.

Connectivity data may include high-level cellular or online-state information where available.

It should not be interpreted as proof that a remote command can currently be executed.

Vehicle availability, capability and command delivery are separate concepts.

---

## Software and updates

Hisingen can display software/update information reported by supported Polestar vehicles.

Depending on what the provider exposes, this can include:

- installed or reported software version;
- availability of an update;
- update state;
- scheduled installation information;
- update progress or completion state.

Software rollout is controlled by Polestar and the vehicle.

Hisingen cannot make an update available to a vehicle before the provider and vehicle consider it eligible.

Where supported, Hisingen may expose actions for an update that has already reached an appropriate installable state.

Hisingen does not bypass:

- rollout eligibility;
- vehicle-side prerequisites;
- update verification;
- provider-controlled installation restrictions.

---

## Location

When Vehicle Location is enabled, Hisingen can request the latest vehicle position available from the provider.

This should be understood as **last-known provider location**, not continuous real-time tracking.

Depending on the response, Hisingen may be able to display:

- latitude and longitude;
- an approximate human-readable location;
- other location-related information reported by the vehicle.

Current vehicle coordinates are not stored in Hisingen's persisted telemetry cache.

See [Privacy](../security/privacy.md).

---

## Weather

Vehicle weather is a separate optional feature.

When enabled, Hisingen can use the vehicle's coordinates to retrieve weather information for its location.

Weather data is not required for normal vehicle monitoring and can be disabled independently.

See [Privacy](../security/privacy.md) for the external services involved.

---

## Vehicle images

Hisingen can retrieve Polestar studio imagery matching the vehicle configuration when the required metadata is available.

The current application supports six Polestar render positions:

1. front three-quarter;
2. front;
3. side;
4. rear three-quarter;
5. rear;
6. overhead.

Downloaded images are cached locally so they do not need to be fetched on every refresh.

Vehicle imagery is presentation data and is independent of telemetry refreshes.

---

## Remote controls

Remote control support is intentionally conservative.

A control is available only when all relevant layers agree:

1. Hisingen implements the command for the Polestar provider;
2. the vehicle capability profile permits it;
3. the corresponding feature is enabled;
4. required user confirmation or local authentication succeeds;
5. the provider accepts the request.

Depending on vehicle support, Hisingen may expose controls involving:

- climate;
- locking;
- windows/openings;
- charging;
- charging limits;
- schedules;
- other supported vehicle functions.

### Capability is not the same as implementation

A vehicle may technically support a feature that Hisingen has not implemented.

Likewise, Hisingen may implement a provider operation that is unavailable for a particular vehicle.

The UI therefore considers both provider implementation and vehicle capability.

### User authorization

Remote features are opt-in.

Actions with greater security or physical consequences require additional confirmation, and sensitive actions can require Touch ID or the Mac login password through macOS device-owner authentication.

See:

- [Vehicle Domain Model](../domain/vehicle.md)
- [Security Overview](../security/overview.md)
- [Threat Model](../security/threat-model.md)

### Command completion

Vehicle commands are asynchronous.

An accepted or delivered provider response does not necessarily mean the requested physical state has already been reached.

Hisingen distinguishes between command outcomes where possible and refreshes vehicle state after remote operations instead of treating every acknowledgement as proof of execution.

---

## Capability detection

Hisingen does not rely solely on a hard-coded table of model names.

The capability system combines:

- conservative model defaults;
- provider implementation support;
- observations from successful API responses;
- observations about unavailable features;
- previously learned capability information with bounded lifetime.

This is important because two vehicles with similar names may expose different capabilities due to:

- model year;
- platform;
- market;
- account permissions;
- software version;
- vehicle configuration;
- staged backend changes.

A failed request by itself is not enough to permanently mark a capability unsupported.

See [Capabilities](../architecture/capabilities.md).

---

## Refresh and rate limiting

Hisingen is designed to avoid unnecessary load on provider services.

The refresh system includes:

- one coordinated refresh path;
- request coalescing;
- retry/backoff for transient failures;
- provider rate-limit handling;
- feature-specific cooldowns;
- preservation of usable state when one optional request fails.

A failure in an optional feature should not normally make the entire vehicle unavailable.

For example, failure to retrieve software information should not prevent Hisingen from displaying battery and charging state.

See:

- [Refresh System](../architecture/refresh-system.md)
- [Errors and Rate Limits](errors-and-rate-limits.md)

---

## Error handling

Provider errors are translated into Hisingen's shared vehicle-service error model.

The application distinguishes cases such as:

- authentication required;
- insufficient permissions;
- unsupported functionality;
- temporary network failure;
- rate limiting;
- provider/server failure;
- invalid or changed response formats.

Optional capabilities generally degrade independently.

Authentication and other session-wide failures are surfaced to the user rather than silently hidden.

---

## Privacy

For Polestar functionality, Hisingen necessarily sends information to Polestar's services, including:

- account authentication information during sign-in;
- session credentials;
- the selected VIN;
- requests for enabled vehicle features.

Hisingen does not operate its own telemetry backend.

Current vehicle coordinates are not persisted in Hisingen's on-disk vehicle-state cache.

The VIN and a limited subset of vehicle/charging information may be cached locally to support useful behaviour when a vehicle or provider is temporarily unavailable.

See [Privacy](../security/privacy.md) for the exact data-retention model.

---

## Security

The Polestar integration handles credentials capable of accessing sensitive vehicle information and, where enabled, vehicle actions.

Relevant protections include:

- macOS Keychain storage for long-lived secrets;
- PKCE during authentication;
- authentication-state validation;
- HTTPS/TLS;
- feature-level command opt-in;
- capability checks before command dispatch;
- confirmation before remote actions;
- macOS device-owner authentication for sensitive operations;
- signed and notarized production releases.

See [Security Overview](../security/overview.md).

---

## Unsupported and unknown behaviour

The integration deliberately fails conservatively.

Hisingen should not:

- invent a value when a field is absent;
- assume a command works because another model supports it;
- mark a capability unsupported after one transient error;
- expose a remote control solely because a matching domain capability exists;
- assume a provider acknowledgement means the vehicle physically changed state;
- attempt to bypass provider or vehicle safety restrictions.

Unknown behaviour should be represented as unknown, unavailable or backend-dependent until there is sufficient evidence to classify it more precisely.

---

## Compatibility expectations

Because this is an undocumented integration, upstream changes are expected over the lifetime of the project.

Changes may affect:

- authentication;
- vehicle discovery;
- response formats;
- available telemetry;
- individual capabilities;
- remote controls;
- vehicle imagery;
- software/update information.

When this happens, Hisingen should degrade gracefully wherever possible rather than making unrelated functionality fail.

Bug reports involving provider behaviour should include:

- Hisingen version;
- macOS version;
- Polestar model and model year;
- affected feature;
- whether the issue is consistent or intermittent.

Do **not** include:

- account passwords;
- access or refresh tokens;
- full VINs;
- precise home/vehicle coordinates;
- raw unsanitized provider responses.

See [Security Policy](../../SECURITY.md) for sensitive reports.

---

## Contributor guidance

When changing the Polestar integration:

- preserve the shared provider/domain boundary;
- keep network operations feature-gated;
- handle missing fields as missing;
- sanitize all fixtures before committing them;
- never commit captured traffic from a real account;
- never commit real credentials or tokens;
- avoid putting detailed reverse-engineering findings into public documentation;
- add regression coverage for provider-response changes;
- ensure new remote actions participate in both capability and implementation gating;
- fail safely when provider behaviour is uncertain.

Sanitized fixtures belong in the public test suite.

Raw captures, probing transcripts, credential-bearing responses and detailed reverse-engineering research do not.

---

## Related documentation

- [API Overview](overview.md)
- [Authentication](authentication.md)
- [Errors and Rate Limits](errors-and-rate-limits.md)
- [Vehicle Domain Model](../domain/vehicle.md)
- [Capability Matrix](../domain/capability-matrix.md)
- [Charging](../domain/charging.md)
- [Provider Architecture](../architecture/providers.md)
- [Capabilities](../architecture/capabilities.md)
- [Refresh System](../architecture/refresh-system.md)
- [Privacy](../security/privacy.md)
- [Security Overview](../security/overview.md)
- [Threat Model](../security/threat-model.md)
- [Testing Strategy](../testing/strategy.md)

---

## Disclaimer

The Polestar integration is an independent open-source implementation.

Hisingen is not affiliated with, endorsed by, sponsored by, or maintained by Polestar Performance AB.

Polestar names and trademarks are used only to identify compatibility.

Undocumented provider interfaces may change, become unavailable, or behave differently without notice. Users remain responsible for complying with any terms applicable to their Polestar account and services.
