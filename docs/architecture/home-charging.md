# Home Charging Architecture

Home charging is a second subsystem beside the vehicle providers. It reads a charger, sends it two
commands, imports its finished sessions, prices them, and adds the grid tariff and house meter. It
shares no code path with [`VehicleProviding`](providers.md) or the
[refresh loop](refresh-system.md). For the reader-facing behaviour, see
[Home charging](../home-charging.md).

## Parts

| Part | Where | Role |
|---|---|---|
| `HomeChargingModel` | `Services/HomeCharging/HomeChargingModel.swift` | The `@MainActor` model the UI observes. Owns pairings, polling, commands, session import and the Tibber and house-meter state. `AppDelegate` creates it lazily. |
| `HomeChargingStore` | `Services/HomeCharging/HomeChargingStore.swift` | Reads and writes the pairings, plan records, grid tariff and Tibber choice in `UserDefaults`, and the logins in the Keychain. |
| `ChargerSource` | `Domain/HomeCharging/ChargerSource.swift` | The four ways to reach a charger: `homeAssistant`, `easee`, `zaptec`, `nexBlue`. `isDirect` is true for the three vendor clouds. `supportsPlans` is true only for Home Assistant. |
| `DirectChargerProvider` | `Services/HomeCharging/Direct/` | One vendor cloud reduced to what the card and history need. `EaseeProvider`, `ZaptecProvider` and `NexBlueProvider` implement it. |
| Home Assistant | `HomeAssistantClient`, `HomeAssistantSocket`, `HomeChargerDiscovery` | REST calls and a live socket to the reader's own instance, and the discovery that finds a charger's entities. |
| Tibber | `Services/HomeCharging/Tibber/` | Prices, consumption, production and the live house-power stream. |
| Perific | `Services/HomeCharging/Perific/` | The house meter: client, store and model. |
| Prices and tariff | `Domain/ElectricityPrices.swift`, `ElectricityRate.swift`, `GridTariff.swift`, `GridTariffRegion.swift`, `Services/Market/` | The Charging Planner, the rate policy, the Swedish spot-price service and the grid tariff. |
| Carbon and alerts | `Domain/GridCarbon.swift`, `Services/API/ElectricityMapsClient.swift`, `Domain/PriceThresholdAlert.swift`, `Services/Integration/PriceAlertController.swift` | The live carbon line and the price threshold alert. |

## One protocol for the vendor clouds

```swift
protocol DirectChargerProvider: Sendable {
    var source: ChargerSource { get }
    func chargers() async throws -> [DirectChargerSummary]
    func telemetry(chargerID: String, now: Date) async throws -> HomeChargerTelemetry
    func send(_ kind: HomeChargerCommandKind, chargerID: String, telemetry: HomeChargerTelemetry) async throws
    func sessions(chargerID: String, from: Date, to: Date) async throws -> [HomeChargingSessionCandidate]
    var sessionLookback: TimeInterval { get }
}
```

A provider never decides anything for the reader. It reads, it sends the command it is given, and it
lists finished sessions. `chargers()` signs in on the way, so setup uses it as the credential check.
All three providers look back 30 days for the first import. A reading carries the time the cloud
last vouched for the value, the same contract the Home Assistant path keeps, so staleness and
command confirmation work the same for every source.

`HomeChargerCommandKind` has two cases, `start` (Charge Now) and `pause`. Each vendor maps them to
its own calls, and the mapping is in each provider's `send`.

`DirectChargerProviders.make` builds Easee and Zaptec from a login. It returns `nil` for Home
Assistant and for NexBlue. NexBlue is built from its refresh token through `NexBlueProvider.signIn`
and `refresh`, because the password is used once and only the rotating refresh token is stored.

`BearerSession` is the actor behind the token handling. It signs in once, reuses the token until
shortly before it expires, and signs in again once when the vendor says the token is no longer
good. It uses the same network seam as the Home Assistant client (`HomeAssistantTransport`), so a
test answers from a route table and nothing real is called.

Errors are `DirectChargerError`. Their descriptions never carry the account, the password, a token
or a request header. `isTransient` is true for `unreachable`, `chargerOffline`, `rateLimited` and a
rejection with status 500 or above, and false for the rest.

## Polling and the command loop

`HomeChargingModel` runs its own loop, separate from the vehicle `RefreshCoordinator`:

| What | Interval |
|---|---|
| The live charger | 60 seconds (`pollInterval`) |
| The live charger while a command waits | 10 seconds (`pendingPollInterval`) |
| Chargers that are not the live connection | 5 minutes (`secondaryPollInterval`) |
| Session import | At most every 30 minutes (`syncInterval`) |

With more than one charger, one connection keeps the sockets, the plan and the command feedback.
The others stay visible with their own readings and ages, without a second stream of traffic.

`HomeChargerCommandTracker` follows a command from the tap to the charger's own answer. A successful
call means the cloud or the integration accepted it and nothing more, so acceptance only moves the
command to "waiting for the charger". The result is read from a status reading stamped after the
acceptance. A reading from before the command can never confirm it, and a window that closes without
one is reported as unconfirmed and not as success. The unconfirmed reasons are `timedOut`,
`delayedStartActive`, `chargerError` and `noFreshReading`.

## Sessions

Imported sessions land on the vehicle's own `charging_sessions` row, so one physical charge is one
row. A session is matched by its key, then by overlap on the same charger, and only then added.
See [Persistence](persistence.md#charging_sessions) and
[Charging](../domain/charging.md#charging-session-history).

## Prices and the planner

`PreferencesStore.hasPriceSource` decides whether any price series can be read: a connected Tibber
home with Tibber chosen as the supplier, or the country set to Sweden. The Charging Planner and the
price threshold alert need it, and the planner also needs its feature switch. A Tibber home works in
any country, which replaced an earlier check that tested only for Sweden.

Prices come from Tibber's own API when a home is connected. Home Assistant's `tibber.get_prices`
service is the fallback. Without Tibber, Swedish spot prices come from `ElectricityPriceService`,
which fetches once a day after 14:15 Stockholm time and keeps the series in the
[`electricity_prices` tables](persistence.md#electricity_prices-and-electricity_price_fetches).

## Grid tariff

`GridTariff` is the transfer fee on top of the electricity price. `GridTariffRegion` is the
country: Sweden, Norway, Denmark, Germany or the Netherlands. The region decides the currency, the
unit, and the calendar the high-load window follows, so the window uses the grid company's time
zone and not the Mac's. Only Sweden and Norway carry presets (`vattenfall(_:fuseAmps:)` and
`elvia()`). `isPreset` is true only in the preset's own country, and `normalizedForMarket` turns a
preset that has moved to another country into the reader's own figures with the money cleared.
Another country keeps the weekday rule alone, because only Sweden's public holidays are known.

The tariff is stored under `home_charging_grid_tariff_v1`.

## Secrets and network

Every login lives in the Keychain under `charger-credentials-<vendor>`, and
[Keychain](../security/keychain.md) lists them. Every request is HTTPS except a Home Assistant
address the reader chose as `http`. See [Security overview](../security/overview.md#network-transport).
