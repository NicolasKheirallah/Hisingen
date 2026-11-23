# Adding a Charger Source

What it takes to connect another home-charger vendor directly. This is the home-charging
counterpart of [Adding another provider](adding-a-provider.md), which covers vehicle brands. Read
[Home charging architecture](../architecture/home-charging.md) first.

A charger that Home Assistant already supports needs none of this. Home Assistant is a
`ChargerSource` of its own, and discovery or a manual mapping finds the charger. Add a direct source
only when the vendor's cloud is worth reading without Home Assistant.

## What you get for free

- The charging card, Charge Now and Pause, the command loop and its confirmation rules.
- The 60-second poll, the 10-second poll while a command waits, and the session import schedule.
- Session matching onto the vehicle's `charging_sessions` row, and pricing with the rate policy,
  Tibber and the grid tariff.
- Credential storage in the Keychain under `charger-credentials-<vendor>`.

## What you implement

1. **A `ChargerSource` case.** Add it to `Domain/HomeCharging/ChargerSource.swift` with a raw value,
   which is also the vendor name in the Keychain account, and a `providerName`. `isDirect` is true
   for everything except Home Assistant. `supportsPlans` stays true only for Home Assistant, because
   a plan has to keep running while the Mac sleeps and nothing in Hisingen does that for a direct
   charger.
2. **A `DirectChargerProvider`.** Add a file under `Services/HomeCharging/Direct/` that implements
   `chargers()`, `telemetry(chargerID:now:)`, `send(_:chargerID:telemetry:)`,
   `sessions(chargerID:from:to:)` and `sessionLookback`. Use `BearerSession` for the token, so a
   sign-in happens once, the token is reused until shortly before it expires, and one fresh sign-in
   follows a refusal. `chargers()` doubles as the credential check during setup.
3. **Commands.** `HomeChargerCommandKind` has `start` and `pause`. Map each to the vendor's calls.
   If the vendor has no equivalent, say so in the provider and in the docs, as Zaptec does for
   Charge Now, which resumes a pause or a schedule. Success means the cloud accepted the command.
   The charger's own answer arrives in later telemetry, and the command tracker judges it.
4. **Telemetry that says when.** Fill `HomeChargerTelemetry` with the time the cloud last vouched
   for each value, so staleness and confirmation work. Leave a reading you do not have as unknown,
   not as zero. A status the table does not know stays `.unrecognised` with its raw token.
5. **Errors.** Throw `DirectChargerError`. Its descriptions never carry the account, a password, a
   token or a header, and a new case has to keep that.
6. **Registration.** Return the provider from `DirectChargerProviders.make`. A source that signs in
   with a rotating token, as NexBlue does, is built from that token elsewhere. Store the secret
   through `HomeChargingStore`, never in preferences.
7. **Sessions.** Return `HomeChargingSessionCandidate` values for sessions that ended inside the
   window, and leave a running one out. The ledger matches them by key, then by overlap on the same
   charger.

## Tests

Answer from a route table through the `HomeAssistantTransport` seam, the same one the Home Assistant
client uses. No test calls a real account. `DirectChargerProviderTests` and `NexBlueProviderTests`
are the patterns to copy, and `DirectChargerModelTests` covers the model around a provider. Keep
live checks out of the default run, and describe them in
[Home charging](../home-charging.md) the way the Easee and Zaptec live checks are.

## Documentation to update

A new vendor changes these pages, and a change that skips one leaves the privacy claims wrong:

- [Home charging](../home-charging.md): the setup steps, the table of what Hisingen uses, and the
  host row under Privacy and data.
- [Keychain](../security/keychain.md): the new `charger-credentials-<vendor>` row.
- [Privacy](../security/privacy.md) and [System context](../architecture/system-context.md): the host
  and what it receives.
- [Data retention](../data-retention.md) if the source stores anything new.
- The README bullets and `CHANGELOG.md`.
