# Adding a New Vehicle Feature

Worked example using a real, representative pattern already in the codebase — adding a new optional telemetry field that one or both providers can supply. This is the pattern `batteryDiagnostics`, `airQuality`, `connectivity`, etc. all follow.

## 1. Identify the authoritative API source

Confirm which provider(s) actually expose the data, and how confident that source is — see [api/overview.md#api-confidence](../api/overview.md#api-confidence). For Polestar, that likely means finding the right gRPC service/GraphQL field by inspecting real traffic or existing `PolestarGRPC*.swift` parsers for a similar shape. For Volvo, check the documented Connected Vehicle/Energy API reference at developer.volvocars.com.

## 2. Determine provider/model availability

Is this universal, brand-specific, or model-specific? Decide the static default in `VehicleCapabilityProfile.support(for:)` accordingly — conservative (`.backendDependent`) unless you have real evidence it's broadly supported. Don't add a new `switch model` branch scattered elsewhere; this table is the one place model-specific defaults belong. See [architecture/capabilities.md](../architecture/capabilities.md).

## 3. Add the domain field

Add the new field to the relevant struct in `Domain/VehicleDomainTypes.swift` (or a new struct if it's a distinct concept), then thread it through `VehicleState`'s stored properties, memberwise initializer, `CodingKeys`, and `init(from:)`. If the field should ever be cached to disk, remember to also add it to `cacheableCopy`'s explicit argument list — omission there means "never cached," not "cached by default." See [domain/vehicle.md](../domain/vehicle.md) and the caveat in [security/privacy.md](../security/privacy.md#what-the-local-cache-actually-retains).

## 4. Add an `AppFeature` case (if it's independently toggleable)

`Domain/AppFeature.swift` — add the case, its `title`/`detail` localized strings, and decide whether it belongs in `FeatureSelection.default`. This is what gates both the network call and the UI card.

## 5. Add the provider-side DTO and decode logic

In `PolestarAPI.swift`/`PolestarGRPC*.swift` or `VolvoAPI.swift`/`VolvoModels.swift`: add the request, the `Decodable` DTO (or protobuf field parsing for Polestar gRPC), and wrap it in the existing optional-fetch helper (`optionalCapability` for Polestar, `optional` for Volvo) so a failure degrades gracefully rather than failing the whole refresh. Map the DTO into the domain field inline in `fetchVehicleState` — that's the established pattern; see [architecture/data-flow.md](../architecture/data-flow.md#dto-domain-ui).

## 6. Wire capability tracking

If a successful fetch should record a positive capability observation, call `probes.record(_:as: .supported)` (Polestar pattern) or update the profile from an explicit capabilities endpoint if one exists (Volvo pattern, see [api/volvo.md](../api/volvo.md#capabilities)). Don't invent a negative-recording path unless you have an explicit, trustworthy backend signal for "unsupported" — the whole point of this system is that a failed fetch alone never proves unsupported. See [architecture/capabilities.md](../architecture/capabilities.md).

## 7. Update `mergingLastKnown`

Add the field to `VehicleState.mergingLastKnown(from:features:)` following the existing pattern: new value wins if present, otherwise keep the previous value only if the feature is enabled *and* this fetch specifically listed it in `unavailableFeatures`. See [architecture/data-flow.md#data-merging](../architecture/data-flow.md#data-merging).

## 8. Add fixtures and tests

A sanitized JSON fixture in `Tests/HisingenTests/Fixtures/` (see [testing/fixtures.md](../testing/fixtures.md)), a decode test against it, and — if the field affects capability resolution or merging — a targeted unit test for that logic. Follow the existing `VehicleCapabilityParsingTests.swift`/`VolvoDecodingTests.swift` patterns rather than inventing a new test-organization scheme.

## 9. Expose it in the UI

Add a card/row in `UI/HisingenContentView.swift`'s `VehicleTabView` (or wherever fits), gated by `Preferences.features.contains(.yourNewFeature)` and, if relevant, `VehicleCapabilityProfile.permits(_:)`. Follow the existing pattern of returning `nil`/hiding the card entirely when data or the feature toggle is absent, rather than showing an empty or zero-valued placeholder.

## 10. Update documentation

At minimum: [domain/capability-matrix.md](../domain/capability-matrix.md) if you added a capability, and the relevant [api/polestar.md](../api/polestar.md)/[api/volvo.md](../api/volvo.md) endpoint table. If the field is sensitive (location, PII), update [security/privacy.md](../security/privacy.md) too.

## Real example to read alongside this guide

`batteryDiagnostics` is a good end-to-end reference: `Domain/VehicleDomainTypes.swift` (`BatteryDiagnostics` struct), `Domain/AppFeature.swift` (`.batteryDiagnostics` case), `PolestarAPI.swift` (gRPC fetch + `optionalCapability` wrapping), `VehicleState.mergingLastKnown` (its merge branch), and `HisingenContentView.swift` (its card, inside the "More" disclosure group).
