# Test Fixtures

`Tests/HisingenTests/Fixtures/` — 26 JSON files, real (sanitized) response shapes used by the fixture-based decode tests described in [strategy.md](strategy.md).

## Naming convention

`<domain>-<state>.json`. Bare names (`vehicle-*`, `account-cars-multi`, `graphql-error`, `vdms-discovery`) are Polestar GraphQL/gRPC-adjacent fixtures. Everything prefixed `volvo-` is a Volvo REST fixture, named after its endpoint (`volvo-doors`, `volvo-tyres`, `volvo-statistics`, ...) or, for vehicle details, its powertrain variant (`volvo-vehicle-details-bev/phev/ice/partial/unknown-fields`). State variants use a suffix, e.g. `volvo-doors-open.json` for the "something is open" case alongside the baseline `volvo-doors.json`. `vdms-discovery.json` is the newer VDMS vehicle-discovery shape; `account-cars-multi.json` is the legacy `getConsumerCarsV2` shape.

## Directory contents

```
account-cars-multi.json        graphql-error.json           vdms-discovery.json
vehicle-charging.json          vehicle-complete.json         vehicle-fault.json
vehicle-not-charging.json      vehicle-partial-response.json
volvo-diagnostics.json         volvo-doors.json               volvo-doors-open.json
volvo-energy-capabilities.json volvo-energy-state.json        volvo-fuel.json
volvo-location.json            volvo-odometer.json            volvo-statistics.json
volvo-token-response.json      volvo-tyres.json                volvo-windows.json
volvo-vehicle-details-bev.json volvo-vehicle-details-ice.json
volvo-vehicle-details-phev.json volvo-vehicle-details-partial.json
volvo-vehicle-details-unknown-fields.json volvo-vehicles-list.json
```

## Sanitization — what "sanitized" means here, verified

Every fixture in the directory uses clearly fake data — no real VIN, token, name, registration, address, or coordinate has been found in any of them. The patterns used:

- **Obviously fake VINs**: `YSMTEST0000000001` (`vehicle-complete.json`/`vehicle-fault.json`, explicit `TEST` marker), `LP5SVSEDEKML000001`/`LP2SVSEDEKML000002` (`account-cars-multi.json`, plausible-shaped WMI prefix but transparently sequential fake suffixes), `YV1FIXTURE0000001` (`volvo-vehicle-details-bev.json`, explicit `FIXTURE` marker).
- **`example.invalid` for URLs** — an RFC 2606-reserved, guaranteed-non-resolving TLD, used for image URLs in vehicle-details fixtures. This is the correct pattern; new fixtures needing a placeholder URL should use the same domain.
- **Explicit fixture markers in tokens**: `volvo-token-response.json`'s `access_token`/`refresh_token` are literally the strings `"fixture-access-token-not-real"` / `"fixture-refresh-token-not-real"`.
- **Placeholder registration plates**: `ABC123`/`DEF456` in `account-cars-multi.json`.
- **One geographic point worth knowing about**: `volvo-location.json` uses coordinates `[11.9746, 57.7089]` — central Gothenburg, Sweden. This isn't a real user's location; it's Volvo's home city and, not coincidentally, the source of the app's own name (Hisingen is an island in Gothenburg). It reads as a deliberate thematic placeholder, not leaked PII, but it is a real, non-randomized geographic point rather than an obviously-fake one like the VIN patterns above — worth a second look if fixture provenance is ever audited more strictly.

## Adding a new fixture

1. Capture the real response shape (from your own account, via a debugger breakpoint or a temporary log statement — never commit a captured response directly).
2. Replace every real value with an obviously-fake equivalent, following the existing conventions above: a VIN containing `TEST`/`FIXTURE`, `example.invalid` for any URL, and a token string that says `fixture-...-not-real` rather than a random-looking but real-shaped string (a real-shaped fake token is a false sense of security if it's ever mistaken for genuine).
3. Keep the field *shape* faithful — including fields that are `null`/missing in the real response, since the point of these fixtures is testing how the decoder handles a real, sometimes-partial payload, not a hand-idealized one. `volvo-vehicle-details-partial.json` and `volvo-vehicle-details-unknown-fields.json` exist specifically to test bare-root-vs-wrapped envelope handling and tolerance of fields Hisingen doesn't model yet.
4. Name it following the `<domain>-<state>.json` convention above.
5. Write the decode test against it in the matching `Unit/` test file (`VolvoDecodingTests.swift` for Volvo, `GraphQLDecodingTests.swift`/`VehicleCapabilityParsingTests.swift` for Polestar), not a new file, unless you're covering a genuinely new area.

## Updating an existing fixture

If a real API response shape changes (new field, renamed field, different envelope), update the fixture to match and re-run the corresponding decode test — a fixture that's drifted from reality is worse than no fixture, since it gives false confidence. See [operations/troubleshooting.md](../operations/troubleshooting.md#an-api-response-schema-changes) for the maintainer runbook when this happens for real.

## Protecting personal vehicle data

Never commit a raw captured response, even temporarily, even in a draft PR — sanitize before the first commit that includes it. If you're testing against your own real vehicle during development, treat anything printed/logged from that session as sensitive and don't paste it into an issue or PR description without sanitizing it the same way these fixtures are sanitized.
