# Home charging

Home charging is optional. It connects Hisingen to a charger that Home Assistant manages, so the
panel can show what the charger reports beside what the car reports, run a charging plan that
survives the Mac sleeping, and record the energy and cost the charger measured.

The feature has two halves:

| Half | Where it runs | What it does |
|---|---|---|
| Hisingen | Your Mac | Connects to Home Assistant on the local network, shows charger state, sends commands, submits plans, imports finished sessions |
| Home Assistant component | Your Home Assistant | Runs a submitted plan, records sessions, publishes the plan status sensor |

Status, controls and charger history work with only the app half. **Plans need the component**,
because Home Assistant is what keeps running when the Mac sleeps or Hisingen is closed; the plan
editor says so when it is missing.

## Requirements

- Home Assistant reachable from the Mac on the local network, over `http` or `https`.
- A charger integration in Home Assistant. NexBlue is discovered first; any charger that exposes
  a switch, a charging-state sensor, a power sensor and a session-energy sensor can be mapped by
  hand.
- A Home Assistant long-lived access token. Create one in your Home Assistant profile under
  **Security**. A token from an administrator also reads the device registry, which finds the
  charger's serial number; a non-administrator token falls back to matching entity names.
- Optional: the Tibber integration, for price-aware windows.
- Optional: a battery sensor in Home Assistant, for plans that target a percentage.

## Install the Home Assistant component

1. Copy `home-assistant/custom_components/hisingen_home_charging` into your Home Assistant
   `config/custom_components/` folder.
2. Add the domain to `configuration.yaml`:

   ```yaml
   hisingen_home_charging:
   ```

3. Restart Home Assistant. The component registers its services and starts publishing a plan
   sensor per paired charger.

The component is plain Python with no Home Assistant import in its planning, engine or session
recorder. Its unit tests run without a Home Assistant install:

```sh
sh Scripts/test-home-assistant-component.sh
```

### What the component exposes

Services: `register_charger`, `submit_plan`, `preview_plan`, `cancel_plan`, `pause_plan`,
`resume_plan`, `charge_now`, `get_status`, `get_sessions`. Their fields are documented in
`services.yaml` beside the component.

The plan sensor is `sensor.hisingen_home_charging_plan_<charger>`, where `<charger>` is the
charger id lowercased with runs of other characters replaced by one underscore. Hisingen builds
the same name from the same rule, so neither side needs a handshake. Its state is one of:

| Phase | Meaning |
|---|---|
| `idle` | No plan |
| `scheduled` | A window is chosen and the start is still ahead |
| `charging` | The plan is charging now |
| `waiting_for_power` | The charger is connected but not delivering |
| `delayed` | The charger is holding a start delay |
| `holding` | The reader paused the plan; no command is sent |
| `override` | Charge now is running and ignores the plan's windows |
| `complete` | The target was reached |
| `unlikely` | The target cannot be met by the deadline at the measured rate |
| `attention` | The charger reported a state the plan cannot act on |
| `cancelled`, `expired` | The plan ended without reaching the target |

## Pair the charger

Open **Settings → Home Charging**:

1. Enter the Home Assistant address, for example `http://homeassistant.local:8123`.
2. Paste the long-lived access token. It is stored in the macOS Keychain, in its own item, and is
   never part of a settings export or a log.
3. Choose **Connect and find chargers**. The app reads Home Assistant's version, entities and,
   with an administrator token, its devices.
4. Pick the charger, or choose **Map by hand** and set the entities yourself. Required: charging
   state, power, session energy and the charging switch. Optional: lifetime energy, current
   limit, charging enabled, cable lock and a battery sensor.
5. Pick the **Vehicle** the charger belongs to. Sessions and plans are tied to that VIN; a car
   being near the charger does not tie it.
6. Optionally pick the car's saved **Charge location** for this charger, mark the charger as
   shared, and set the network fee in öre per kWh.
7. Choose **Pair charger**.

`HomeChargingPairing`, `HomeChargerEntityMap` and `HomeAssistantDiscovery` in
`Sources/Hisingen/Domain/HomeCharging/` hold the pairing, and `HomeAssistantClient` and
`HomeAssistantSocket` in `Sources/Hisingen/Services/HomeCharging/` do the talking.

### A shared charger

When **Other cars also use this charger** is on, a charger session is recorded for this vehicle
only when the car's own charging overlaps it. The charger alone is not proof that this car took
the energy.

## What the charging card shows

`HomeChargerSection` adds a section to the charging card when a charger is paired. In order:

- the vehicle context line, muted, because the car is the subject and the charger is the source;
- the session line, the figure: wall power and the energy delivered in this session;
- the plan line and, when a price is known, the estimated cost;
- a notice when something needs attention;
- the freshness line for the charger's last reading;
- the actions, each a real command: start, pause, resume, stop, or charge now.

The charger's state is never merged into the car's own charging state. A car that reports
"charging" and a charger that reports "connected, not delivering" is a real and useful
disagreement, and the card shows both.

## Plans

The plan editor opens from the charging card. A plan is a target and a deadline:

- **Add energy**: kWh measured at the charger, so charging losses are included.
- **Reach a percentage**: the car's own charge limit is the ceiling, and the percentage comes
  from a battery sensor in Home Assistant that updated recently.

The editor previews the plan before it starts: the chosen window, the average price, the
estimated cost and the expected finish, or a warning that the target is unlikely at the measured
charging rate. Hisingen remembers the rate from recent charger sessions and updates it when the
car charges slower than planned.

Starting a plan submits it to the component, which keeps it. Pause leaves the charger as it is
and sends nothing until the plan is resumed or replaced. Cancel stops the plan and leaves the
charger as it is. Charge now overrides the windows until the target is reached.

When Tibber prices are unavailable, the component charges as soon as the plan starts so the
deadline can still be met, and marks the plan with a `prices_missing` warning. It does not invent
a price. When only part of the horizon has real prices, the rest is filled at an estimated price
and the plan says so.

## Sessions and history

The component records each finished charger session and Hisingen imports them into charging
history. A session carries the energy the charger measured, the cost when a price is known, and a
stable session id derived from its start, so importing twice cannot duplicate it. History rows
show **Charger Energy** and, when it differs from the car's estimate, **Charger Cost**. The CSV
exports and the handover pack include the charger columns.

Imports respect the privacy setting: with local charging history off, the app records nothing and
the pairing shows that. A charger session that cannot be tied to a vehicle is kept unassigned and
reported, rather than dropped or guessed onto the wrong car.

## Prices

Plan windows use Tibber import prices through Home Assistant's `tibber.get_prices` service, in
the currency Home Assistant reports. The network fee from the pairing is added to each price.
Hisingen shows the price source in the preview so an estimate is never mistaken for a published
price.

## Privacy and data

- The long-lived token lives in a Keychain item of its own. It is not written to a settings
  archive, an export, a diagnostic log or a crash report.
- The app talks only to the address you entered. There is no relay, no cloud account and no
  telemetry.
- Charger readings, plans and sessions stay in Home Assistant and in Hisingen's local database.
- **Remove Connection and Token** deletes the token and the pairing. Charging history that was
  already recorded stays, because it is the reader's data.
- macOS asks for local network access the first time the app connects. Denying it leaves the rest
  of Hisingen working; the pairing simply reports that it cannot reach Home Assistant.

## Troubleshooting

| Symptom | Check |
|---|---|
| Token rejected | The token was deleted or expired in Home Assistant. Create a new one. |
| Unreachable | The address, the local network permission in System Settings → Privacy & Security, and that Home Assistant answers in a browser on the same Mac. |
| No charger found | The NexBlue integration is loaded, or map the entities by hand. |
| Charger discovered by entity names | The token is not an administrator. That is supported; the serial number needs an administrator token. |
| Plan editor says the component is not installed | Copy the component into Home Assistant, add `hisingen_home_charging:` to `configuration.yaml` and restart. |
| A plan never starts | The plan phase sensor names the phase. `holding` means the plan is paused, `unlikely` means the deadline cannot be met at the measured rate, `attention` means the charger reported a state the plan cannot act on. |
| Sessions missing | Check **Import sessions now**, the paired VIN, and the shared-charger rule. |

## Uninstall

1. In Hisingen, choose **Remove Connection and Token**, then **Unpair charger**.
2. Remove `hisingen_home_charging:` from `configuration.yaml` and delete the
   `custom_components/hisingen_home_charging` folder.
3. Restart Home Assistant. Its stored plans and recorder state stay unused in Home Assistant's
   `.storage` folder; delete the `hisingen_home_charging` file there to remove them.

## Tests and evidence

- `Tests/HisingenTests/Unit/HomeAssistantClientTests.swift`: requests, errors and decoding from
  captured Home Assistant responses in `Tests/HisingenTests/Fixtures/`.
- `HomeChargerTelemetryTests`, `HomeChargingSessionTests`, `HomeChargingPlanTests`,
  `HomeWallboxLedgerTests`, `HomeChargingModelTests`: discovery, telemetry, the plan payload, the
  ledger and the sync.
- `home-assistant/tests/`: the component's planner, engine and session recorder.
