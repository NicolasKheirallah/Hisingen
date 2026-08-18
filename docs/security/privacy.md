# Privacy

What can leave the user's Mac, verified against the implementation (not just the marketing copy).

## What leaves the Mac

| Service | Data sent | Reason | Optional? |
|---|---|---|---|
| Polestar ID / GraphQL / C3 / PCCS | Login credentials (once, at sign-in), bearer tokens, VIN, requested telemetry fields | Core functionality — required for any Polestar use | No |
| Volvo ID / Connected Vehicle / Energy / Location API | Bearer tokens, VCC API key, VIN, requested telemetry fields | Core functionality — required for any Volvo use | No |
| Apple CoreLocation (`CLGeocoder`) | Vehicle latitude/longitude | Reverse-geocode into a street address for display | **Yes** — only when "Vehicle Location" is enabled |
| Open-Meteo | Vehicle latitude/longitude | Weather at the vehicle's parked location | **Yes** — only when "Vehicle Weather" is enabled |
| GitHub Releases API | Hisingen's own version string (in the `User-Agent` header) | Check for a newer release | **Yes** — only when "Update Checks" is enabled |
| GitHub Pages (`oauth-callback.html`) | The OAuth authorization code/state Volvo already redirected to that page | Bridges Volvo's http(s)-only redirect requirement back to the app | No — required for Volvo sign-in, but the page itself stores nothing (see [api/authentication.md](../api/authentication.md)) |

No data is sent to any server operated by Hisingen's developer — there isn't one. TERMS.md states this directly: *"No vehicle data, credentials, or usage data is collected by, or transmitted to, the developer of Hisingen at any point."* Nothing found in the codebase contradicts that: there's no analytics SDK, no crash reporter, no telemetry endpoint of Hisingen's own.

## Coordinates, specifically

Vehicle coordinates are the most sensitive single data point Hisingen handles. Concretely:

- Fetched from the provider (Polestar's `DtlInternetService`/`GetLastKnownLocation`, Volvo's `/location/v1/vehicles/{vin}/location`) only when the "Vehicle Location" feature is enabled.
- Sent to Apple's `CLGeocoder` (reverse geocoding) only when that same feature is on — this is an Apple system framework call, not a raw HTTP request Hisingen constructs, and Apple's own privacy handling for `CLGeocoder` applies.
- Sent to Open-Meteo, unauthenticated, only when "Vehicle Weather" is separately enabled — this **is** a raw HTTP request Hisingen constructs (`api.open-meteo.com/v1/forecast`, no API key, coordinates as query parameters).
- Never sent anywhere else. Precise coordinates for *saved charging locations* (as opposed to the vehicle's current position) are explicitly discarded before they ever reach the domain model — Hisingen keeps the schedule's time/weekday/active fields but drops the location and any alias/name attached to it.
- Never written to the on-disk telemetry cache — `VehicleState.cacheableCopy` (`Domain/VehicleState.swift`) builds its persisted copy by calling `VehicleState`'s memberwise initializer with only a specific subset of fields passed explicitly; every field it *doesn't* pass — including `location` and `exteriorStatus` — falls back to that initializer's default value, which is `nil`/empty for all of them. So the current vehicle position never reaches disk, full stop, regardless of feature toggles.

## VIN

Sent to the owning provider (necessarily — it's the primary key for every telemetry/command request), embedded in local notification identifiers (`hisingen.<vin>.<event>`, which stay entirely on-device in Notification Center), and stored in the local telemetry cache and Keychain-adjacent `UserDefaults` (not Keychain itself). Never sent to any third party (Apple, Open-Meteo, GitHub) — those calls only ever receive coordinates or a version string, never a VIN.

## Owner / account data

Owner first name (Polestar's "owner greeting" feature) and registration number are fetched from the provider, shown in the UI, and explicitly **excluded** from the on-disk cache (`cacheableCopy` strips `ownerFirstName` and `registrationNo`) — so a stale/asleep-vehicle scenario shows cached battery/charging data but not a stale cached name or plate number.

## What the local cache actually retains

Worth stating plainly, since "cached" isn't the same as "everything": `VehicleState.cacheableCopy` keeps VIN, model/model-year, battery/charging/range fields, availability, powertrain/fuel fields, capability observations, and charging session history/samples. Because it's built by passing only that subset of fields into `VehicleState`'s initializer, everything else silently reverts to that initializer's default — which strips registration number, owner name, odometer, service/fluid warnings, weather, image data, **and also** exterior/lock status, health details, software info, charging/climate schedules, climate status, trip meters, connectivity, air quality, battery diagnostics, and location. In other words, the persisted cache is closer to "battery and charging state only" than "everything except a documented exclusion list" — the exclusion is implicit (anything not explicitly threaded through is dropped) rather than an explicit strip list, which is worth knowing if you're adding a new field to `VehicleState`: it will **not** be cached unless you also add it to `cacheableCopy`'s explicit argument list.

## Verifying these claims yourself

Every claim above is checkable directly: `Sources/Hisingen/Services/Location/ReverseGeocoder.swift` (Apple-only, no third party), `Sources/Hisingen/Services/API/PolestarGRPCCapabilities.swift`'s `fetchWeather` (Open-Meteo call site and URL), `Sources/Hisingen/Services/Updates/UpdateChecker.swift` (GitHub Releases call site), `Sources/Hisingen/Domain/VehicleState.swift`'s `cacheableCopy` (exact field list retained/dropped for the disk cache).
