# Home charging

## Connect NexBlue directly

1. Open **Settings → Electricity → Home Charging** and choose **NexBlue** under **Charger connection**.
2. Enter your myNexBlue email and password and select **Sign in and find chargers**.
3. Select the charger and vehicle. Choose a saved charge location if you use one, and mark the charger as shared if other cars charge there.
4. Select **Pair charger**. The paired vehicle's charging card shows live status, **Charge now**, and **Pause**. With **Store charging history** enabled, Hisingen imports finished sessions. You can also select **Import sessions now** in Settings.

The direct provider reads from NexBlue's cloud and saves its refresh token in the macOS Keychain. It requests an initial history window of about 30 days. The amount returned depends on the sessions available to your account. Hisingen uses the charger's measured kWh and estimates costs from your electricity settings. For shared chargers, it uses recorded overlap with the vehicle's charging to assign a session. [NexBlue OpenAPI](https://prod-management.nexblue.com/swagger/dist/index.html)

**Charge now** and **Pause** require a current charger status. After NexBlue accepts the command, Hisingen waits for the charger to report the result.

Use **Cheapest overnight charge** on the paired vehicle’s charger card to preview a fixed one-time window using your selected Swedish spot price area. Choose a duration from one to eight hours. Hisingen compares the published prices between 18:00 and 07:00 in the charger’s time zone. An owner account, normal scheduling mode, and a free schedule slot are required. An existing active timer blocks a new one. **Save timer** appends the new window and reads it back from the charger. The charger runs the saved window on its own. To cancel it or clear a used slot, open **Schedule** in myNexBlue. The vehicle’s charging schedule and charge limit still apply. [NexBlue scheduling guide](https://nexblue.com/en-nl/apps/hc/mynexblue-app/how-to-set-the-charging-schedule)

In **Settings → Electricity → Home Charging**, **Import earlier sessions** lets you choose up to one year at a time. Both dates are included. Settings shows when the most recent successful import ran and the date range it checked. Older sessions appear when NexBlue still has them and your account can read them.

## Connect Easee or Zaptec directly

1. Open **Settings → Electricity → Home Charging** and choose **Easee** or **Zaptec** under **Charger connection**.
2. Enter the email and password of the account you use in the vendor's app, and select **Sign in and find chargers**. Use the owner account: a guest or installer account may be refused control.
3. Select the charger and vehicle. Choose a saved charge location if you use one, and mark the charger as shared if other cars charge there.
4. Select **Pair charger**. The paired vehicle's charging card shows status, wall power and delivered energy, **Charge now** and **Pause**. With **Store charging history** on, Hisingen imports finished sessions.

What Hisingen uses, so you can judge what to expect:

| | Easee | Zaptec |
|---|---|---|
| Sign-in | Account and password to `api.easee.com`, one-hour token | Account and password to `api.zaptec.com/oauth/token`, one-hour token, no refresh token |
| Reads | Observations: operating mode, wall power, session energy, dynamic current, reason for no current | Charger state: operation mode, power (W), session energy, final-stop flag, schedule event |
| Pause | `pause_charging` | command 506 |
| Charge now | `resume_charging`, then `start_charging` for a charger that wants authorisation, or `override_schedule` when a schedule holds the start | command 507 |
| Sessions | The charger's session list, with the vendor's session id | Archived sessions, with energy details when Zaptec has them |
| Polling | One request a minute, ten seconds while a command waits | One request a minute, ten seconds while a command waits |

Limits that shape the behaviour:

- **The account and password are stored in the macOS Keychain** and used only to sign in again, because neither vendor's token lasts more than an hour. They never reach preferences, exports, logs or error text. **Sign out** under Home Charging deletes them, as does erasing all data.
- **Charge now on Zaptec resumes a pause or a schedule.** Zaptec has no "start", so a charge that is not paused has nothing to resume, and the card shows Zaptec's own refusal.
- **A pause on Easee sets the charger's dynamic current to 0.** Hisingen shows that as plugged in and held, and Charge now clears it.
- **There are no plans.** A plan has to keep running while the Mac sleeps, and nothing in Hisingen does that for a direct charger. Plans, **Edit plan** and the Hisingen component stay with Home Assistant. A charger connected directly offers status, Charge now, Pause and history.
- **Prices come from Tibber's own API when you connect it** (see [Connect Tibber](#connect-tibber)). Without Tibber, a direct charger's sessions are priced from your electricity settings, and each cost records that method.
- **Readings are stamped with the time of the poll.** Both vendors stamp a value with when it last changed, so a charger that has said "disconnected" for a week would look stale. A charger the vendor reports offline is shown as unavailable instead.

### Live checks for Easee and Zaptec

The automated tests answer from a mock of each cloud, built from the vendors' published documentation; none of them touched a real account or charger. Check these once on yours:

1. **Easee observation ids.** The poll asks for `ids` as one comma-separated string, which is how the documentation types the parameter. If the card stays empty after sign-in, that request is the first place to look.
2. **What a pause looks like.** Press **Pause** on Easee and note the operating mode and reason it then reports. Hisingen expects "awaiting start" with a dynamic current of 0, or "completed". Anything else shows as an unrecognised state.
3. **Zaptec "requesting".** A car that wants to charge but has not started shows as plugged in. Zaptec may use that state for a charger waiting on a load balancer, which Hisingen would then not call "Waiting for available power".
4. **Zaptec schedule event.** State 763 is read as a time. Confirm what it holds with a schedule set and with none.
5. **Command answers.** Easee answers a command with 202 and the result later. Zaptec's refusal for a command the state does not allow may be an HTTP error or a `Code` inside a 200, and Hisingen reads both.
6. **A guest or installer account.** Sign in with one and confirm the charger list is empty or the command is refused with a clear message.
7. **Session lists.** Compare **Import sessions now** with the vendor's app for a recent charge. Easee limits session requests to 10 an hour, so repeated manual imports may be throttled.
8. **Zaptec session energy details.** Check whether a session has readings fine enough (15 minutes or less) to be priced by interval. Without them the cost is a session-total estimate.

## Connect Tibber

Tibber prices charging sessions with no Home Assistant and no charger involved.

1. Create a personal access token at [developer.tibber.com](https://developer.tibber.com).
2. Open **Settings → Electricity → Electricity Supplier**, paste the token and select **Connect and find homes**.
3. Choose the Tibber home and select **Use this home**.

Hisingen asks Tibber's API (`api.tibber.com`) for 15-minute import prices, newest first and page by page, only for the span of the sessions it is pricing. A price is Tibber's all-in `total`: energy, taxes and Tibber's markup, without the grid fee, so the **Network fee** on the paired charger is the only thing added. A session with fine enough readings (Zaptec's energy details) is priced per interval, and one with only a total (Easee, NexBlue) is priced at the time-weighted average over the session. In both cases a missing price slot is shown as missing and never filled. If Tibber cannot be read (a revoked token, a rate limit, no network), the import still runs, the session is priced from your electricity settings, and Settings says why. The token is stored in the macOS Keychain and deleted by **Disconnect Tibber** or by erasing all data.

It works with every charger connection, Home Assistant included: with Tibber connected, its own prices are used first and Home Assistant's `tibber.get_prices` is only the fallback.

Live checks: confirm that the home list shows your home, that a recent session's cost matches the Tibber app within the network fee, and that the first import after connecting prices sessions older than a day (Hisingen reads up to about 40 days of prices, and the cursor paging is the part I could not test against Tibber itself).

## Connect through Home Assistant

Use Home Assistant to pair other supported chargers or run charging plans while the Mac sleeps. Hisingen can show the charger's readings beside the car's and import its charging sessions.

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
- the actions, each a real command: **Charge now**, **Pause**, **Resume** (when a plan is paused) and **Edit plan**.

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

## What the NexBlue integration provides

Checked against the Home Assistant core source (`homeassistant/components/nexblue`, the `dev`
branch) and its documentation page, because the history and plan features depend on it:

- It is a **cloud-polling** integration and reports about once a minute. It has no services, no
  session identifier, no session start or end time and no session list.
- The entities are the `charging_state` enum sensor (`idle`, `connected`, `charging`, `finished`,
  `error`, `lb_waiting`, `delay_waiting`, `ev_waiting`), `power` (kW), `energy` (kWh, the current
  session, state class `total`), `lifetime_energy` (kWh, `total_increasing`), `current_limit`,
  per-phase current and voltage, a `Charging enabled` binary sensor, a `Cable lock state` binary
  sensor and one **charging switch**.
- The switch reads **on** for `charging`, `lb_waiting` and `ev_waiting`, and it flips to its new
  value the moment a command is accepted, before the charger has answered. That is why Hisingen
  confirms a command from the `charging_state` sensor and not from the switch.
- `lb_waiting` is the charger waiting for the load balancer, `delay_waiting` is a delayed start on
  the charger, and `ev_waiting` is the charger ready and waiting for the car.

Consequences:

- **No vendor session id exists**, so sessions cannot be keyed by one. Hisingen keys a session by
  the start of the rise in the session-energy counter (`ha:<charger>:<start>`), and the component
  keys by its own stable id (`capture:<charger>:<id>`). The vendor-id slot exists for chargers that
  expose one.
- **Home Assistant's recorder keeps ten days** of state history by default, so reconstruction from
  history only reaches back that far. The component records every finished session when it ends,
  with the charger's energy per 15-minute interval, so sessions finished while Hisingen was closed
  are imported later without that limit.
- **Interval pricing needs interval data.** The session counter is read about once a minute, which
  is fine enough to price against 15-minute prices. A rise recorded across a gap of more than 20
  minutes is a total, not a profile, and is priced as an estimate with the method recorded.

## Charger commands and what "done" means

A successful Home Assistant call means the command was accepted, nothing more. The card keeps the
action pending, saying so, until a charger reading **stamped after the command** shows the result:

- **Charge now** is confirmed by `charging`, `lb_waiting` or `ev_waiting`. `charging` with no power
  drawn is reported as exactly that: enabled, and the car is not taking power.
- **Pause** is confirmed by `connected`, `finished`, `delay_waiting` or `idle`.
- A reading from before the command never confirms it. If no matching reading arrives within two
  and a half minutes the card says the charger did not confirm, and names a delayed start or a
  charger error when that is what it saw.
- A rejection (Home Assistant answers with an error, for example the charger is offline) is shown
  with Home Assistant's message. A command the charger already satisfies is not sent.

Every reading carries the time Home Assistant last confirmed it. After ten minutes without one the
card shows the last known values, labelled as such, and never as live figures. When Home Assistant
cannot be reached the card says so and keeps the vehicle's own data working.

## Who owns charging: plans, the car and other schedules

- **One owner at a time.** While Home Assistant runs a plan for a vehicle, Hisingen's own Charging
  Planner on the Mac sends no start command and posts no window banner for that vehicle. The
  ownership is remembered across a relaunch and while Home Assistant is unreachable, and ends when
  Home Assistant reports the plan finished, cancelled or expired.
- **Pause is a hold.** It stays until you resume or edit the plan, including across a Home Assistant
  restart. **Charge now** is a visible override until the target is reached.
- **The car's charge limit is the ceiling.** The plan never targets past it, and a charger that
  reports `finished` while energy is still missing (and was not stopped by the plan) ends the plan
  with a note that the car reached its own limit.
- **Conflicts are listed while you set a plan up:** active charging schedules in the car, optimised
  charging at the paired location, Charge now left on in the car, a NexBlue delayed start seen on
  the charger, and enabled Home Assistant automations that use the charger's switch (the last
  needs an administrator token). NexBlue EcoPilot is not visible to Home Assistant; a delayed
  start is the only sign of it, and the plan reports it.

## Load balancing (Perific and Enegic)

Perific stays in charge of dynamic load balancing, and Hisingen does not talk to it. When the
charger reports `lb_waiting` the card says **Waiting for available power**; charging well below the
session's own peak is reported as reduced power that load balancing can cause. An exact current
allocation would need a live, timestamped signal from Perific on your installation, and none is
assumed.

## Live checks that need your installation

The automated tests use captured Home Assistant responses and a mock endpoint; no test commands a
real charger. These behaviours depend on your hardware and account and should be checked once:

1. **Start and stop with Perific/Enegic active.** Press **Charge now** and **Pause** with the
   operator running. Expect the card to wait, then confirm from `charging_state`. Note whether a
   stop makes NexBlue report `finished` or `connected`: the plan treats `finished` right after its
   own stop as a pause, not as the car being full.
2. **What a NexBlue session is.** Start, pause and resume inside one plug-in and see whether the
   session-energy counter resets at the pause or only on unplug. The recorder handles both, but
   this decides whether one evening shows as one history row or several.
3. **How far history reaches.** Compare **Import sessions now** with a charge from more than ten
   days ago (reconstruction cannot see it) and one made while the Mac was off after the component
   was installed (the component has it).
4. **The battery sensor's freshness.** Open the sensor in Home Assistant and see how old its
   `last_reported` gets. A percentage plan refuses a sensor older than 30 minutes.
5. **`tibber.get_prices` resolution.** Run it in Developer Tools for today and tomorrow and confirm
   15-minute entries, the currency, and that tomorrow appears after about 13:00.
6. **Charger reporting cadence.** Confirm `last_reported` on the charger sensors advances every
   poll. On Home Assistant older than 2024.3 it does not, and a steady reading looks stale.
7. **Command acknowledgment time.** Note how long NexBlue takes to move `charging_state` after a
   command; the card waits two and a half minutes before saying it is unconfirmed.
8. **A restart in the middle of a window.** Restart Home Assistant while a plan is charging. The
   component should read the charger's actual state, send nothing, and carry on.

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

## What was verified about the NexBlue integration

Read from Home Assistant core (`homeassistant/components/nexblue`, dev branch) and its documentation:

- It is a cloud integration that polls NexBlue's service about once a minute.
- Entities per charger: a `charging_state` enum sensor with the states `idle`, `connected`, `charging`, `finished`, `error`, `lb_waiting`, `delay_waiting`, `ev_waiting`; power in kW; session energy in kWh; lifetime energy; current limit and diagnostics; a charging-enabled binary sensor; a cable lock binary sensor; and one switch.
- The switch reads on for `charging`, `lb_waiting` and `ev_waiting`, and flips to its assumed state the moment a command is accepted. That is why Hisingen confirms commands from the charging-state sensor and never from the switch.
- `lb_waiting` is the load balancer holding the charger, which Hisingen words as "Waiting for available power". `delay_waiting` is a delayed start on the charger, such as a schedule or EcoPilot.
- It exposes no session id, no session start or end times, and no actions of its own. Hisingen therefore rebuilds sessions from the session-energy counter (a rise, bounded by a reset of the counter or the cable coming out) and keys them by the recorder timestamp where the rise began, which is fixed for good. The Hisingen component supplies its own stable session ids for what it captures.
- Home Assistant's recorder keeps ten days of history by default.

The Tibber action `tibber.get_prices` returns `prices` per home as `start_time` and `price` entries. The documentation's example shows 15-minute spacing.

Perific/Enegic is not read. Reduced charging and waiting are explained from the charger's own status and measured power.

## Live checks that need your installation

None of these can be run without a real charger. They are the first things to try:

1. **Start and stop with the Perific/Enegic operator active.** Press Charge now, then Pause, a few times, at different times of day. Watch whether the charger confirms within the 2.5-minute window, and what state it reports while the operator is limiting it. If a pause shows `finished` on your charger, the component treats `finished` after its own stop as a pause. Confirm that is what you see.
2. **Which history exists.** In Developer tools, States, check `last_reported` on the charging-state and session-energy sensors; it should advance every minute even when the value is steady. Then run "Import sessions now" and compare the result with the NexBlue app. Check what the session-energy counter does at the start of a new session (reset to zero, or carry on), and whether a pause through the switch ends the NexBlue session.
3. **The 15-minute prices.** In Developer tools, Actions, run `tibber.get_prices` and confirm the entries are 15 minutes apart, that `price` is your all-in price per kWh, and how far back the range reaches. Hisingen's cost method (shown under Estimated Electricity Cost, tap the information button) tells you whether interval prices were found.
4. **Battery sensor freshness.** If you use Reach X%, watch how often the sensor updates while the car is parked and charging. A sensor that updates less than every 30 minutes disables percentage plans by design.
5. **Car schedules and EcoPilot.** Plan with the car's own charging schedule and optimised charging on, then off. The plan editor lists what can compete with the plan. Confirm the car obeys the wallbox when its schedule is off.
6. **Restart recovery.** Start a plan, restart Home Assistant mid-window, and confirm the charger is not stopped and started again, and that the plan sensor comes back with its progress.

Session history is stored only when **Store charging history** is on in Settings. It is off by default, and Home Charging respects that: with it off the import writes nothing.

## Tests and evidence

- `Tests/HisingenTests/Unit/HomeAssistantClientTests.swift`: requests, errors and decoding from
  captured Home Assistant responses in `Tests/HisingenTests/Fixtures/`.
- `HomeChargerTelemetryTests`, `HomeChargingSessionTests`, `HomeChargingPlanTests`,
  `HomeWallboxLedgerTests`, `HomeChargingModelTests`: discovery, telemetry, the plan payload, the
  ledger and the sync.
- `home-assistant/tests/`: the component's planner, engine and session recorder.
