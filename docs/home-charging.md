# Home charging

[Charger setup](#connect-nexblue-directly) · [Tibber](#connect-tibber) · [Home Assistant](#connect-through-home-assistant) · [Electricity prices and the Charging Planner](#electricity-prices-and-the-charging-planner) · [Charger screenshots](product-tour.md#home-charging)

## Connect NexBlue directly

1. Open **Settings → Electricity → Home Charging** and choose **NexBlue** under **Charger connection**.
2. Enter your myNexBlue email and password and select **Sign in and find chargers**.
3. Select the charger and vehicle. Choose a saved charge location if you use one, and mark the charger as shared if other cars charge there.
4. Select **Pair charger**. The paired vehicle's charging card shows live status, **Charge now**, and **Pause**. With **Store charging history** enabled, Hisingen imports finished sessions. You can also select **Import sessions now** in Settings.

The direct provider reads from NexBlue's cloud and saves its refresh token in the macOS Keychain. It requests an initial history window of about 30 days. The amount returned depends on the sessions available to your account. Hisingen uses the charger's measured kWh and estimates costs from your electricity settings. For shared chargers, it uses recorded overlap with the vehicle's charging to assign a session. [NexBlue OpenAPI](https://prod-management.nexblue.com/swagger/dist/index.html)

**Charge now** and **Pause** require a current charger status. After NexBlue accepts the command, Hisingen waits for the charger to report the result.

Open **Charger details** at the foot of the charger card to see what the charger reports about the supply: voltage and current in each phase, the current limit, the cable rating, the circuit fuse, the phase mode, and how the charger reaches the cloud. While charging, a line under the session figure gives the current in each phase next to the limit that applies. The limit row says so when the cable or the circuit fuse is lower than the limit you set. Charging uses the lowest of the three, and the car and load balancing can ask for less, so a low current can have a cause the card cannot see. Phase readings older than ten minutes are left out. NexBlue reports all of it. Zaptec reports the voltage and current of each phase, the cable rating, the phases in use and how it reaches the cloud, and publishes no circuit fuse, so that one row stays off. Easee reports the cable rating, the phase mode and whether it reaches the cloud over Wi-Fi or the mobile network; its per-phase readings are terminal values the documentation does not map to phases, so the voltage and current rows stay off for it. Home Assistant reports none of these values, so the list does not appear for it.

Imported NexBlue sessions record how each one began and ended. Open a session in **Log** to see **Started** (at the charger, remotely, by schedule, by an administrator, on plug-in or after an error) and **Ended** (cable unplugged, charge complete, remotely, by schedule, held by load balancing, and others). A power loss or an emergency stop is marked with a warning. **Remotely** means the command came through the NexBlue cloud and not from the charger. Sessions imported before this release gain their reasons the next time they are imported, and a reason Hisingen has no wording for is left out.

Easee and Zaptec sessions show no **Started** or **Ended** rows: neither vendor's published documentation names a start or an end reason on a session record. Zaptec's constants define session-commit flags, such as a stop by RFID card, but no documented field of the archived-session answer carries them, so nothing is mapped.

Use **Cheapest overnight charge** on the paired vehicle’s charger card to preview a fixed one-time window using your selected Swedish spot price area. Choose a duration from one to eight hours. Hisingen compares the published prices between 18:00 and 07:00 in the charger’s time zone. An owner account, normal scheduling mode, and a free schedule slot are required. An existing active timer blocks a new one. **Save timer** appends the new window and reads it back from the charger. The charger runs the saved window on its own. To cancel it or clear a used slot, open **Schedule** in myNexBlue. The vehicle’s charging schedule and charge limit still apply. [NexBlue scheduling guide](https://nexblue.com/en-nl/apps/hc/mynexblue-app/how-to-set-the-charging-schedule)

In **Settings → Electricity → Home Charging**, **Import earlier sessions** lets you choose up to one year at a time. Both dates are included. Settings shows when the most recent successful import ran and the date range it checked. Older sessions appear when NexBlue still has them and your account can read them. Repeating an import keeps one copy of each session. If a pause ends a session, each session keeps its own energy reading.

## Connect Easee or Zaptec directly

1. Open **Settings → Electricity → Home Charging** and choose **Easee** or **Zaptec** under **Charger connection**.
2. Enter the email and password of the account you use in the vendor's app, and select **Sign in and find chargers**. Use the owner account: a guest or installer account may be refused control.
3. Select the charger and vehicle. Choose a saved charge location if you use one, and mark the charger as shared if other cars charge there.
4. Select **Pair charger**. The paired vehicle's charging card shows status, wall power and delivered energy, **Charge now** and **Pause**. With **Store charging history** on, Hisingen imports finished sessions. The card's **Charger details** disclosure lists the supply values your charger reports, as described under [Connect NexBlue directly](#connect-nexblue-directly).

What Hisingen uses, so you can judge what to expect:

| | Easee | Zaptec |
|---|---|---|
| Sign-in | Account and password to `api.easee.com`, one-hour token | Account and password to `api.zaptec.com/oauth/token`, one-hour token, no refresh token |
| Reads | Observations: operating mode, wall power, session energy, dynamic current, reason for no current, cable rating, phase mode, connection type | Charger state: operation mode, power (W), session energy, final-stop flag, schedule event, phase voltage and current, cable rating, phases in use, network mode |
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
9. **Zaptec per-phase states.** States 501 to 503 and 507 to 509 are documented as the output voltage and current of each phase. Confirm on your charger that they line up with the phases the installation uses; Go and Pro chargers differ in what they report.
10. **Zaptec network mode.** State 150 is documented as "Wifi, LTE, PLC, or none". Confirm the exact wording your charger sends. PLC is left out until it has its own wording.
11. **Easee phase readings.** Easee measures input terminals (IN VOLT T1T2 and its siblings, INT CURRENT T2 to T5), and the documentation does not say which terminal is which phase, so no voltage or current rows appear for Easee. Check a charge against your own wiring if you want them added.
12. **Easee circuit maximum.** Observations 22 to 24 are the circuit's configured maximum current per phase, a setting rather than the fuse rating, so the Circuit Fuse row stays off for Easee.
13. **Session reasons.** Neither vendor documents a start or stop reason on a session record. Zaptec's constants define session-commit flags such as StoppedByRFID and Aborted, but the published reference does not show where the archived-session answer carries them, so the Started and Ended rows stay off for both.

## Connect Tibber

Tibber prices charging sessions with no Home Assistant and no charger involved.

1. Create a personal access token at [developer.tibber.com](https://developer.tibber.com).
2. Open **Settings → Electricity → Electricity Supplier**, paste the token and select **Connect and find homes**.
3. Choose the Tibber home and select **Use this home**.

Hisingen asks Tibber's API (`api.tibber.com`) for 15-minute import prices (the subscription's `priceInfoRange`), newest first and page by page, only for the span of the sessions it is pricing. A price is Tibber's all-in `total`: energy, taxes and Tibber's markup, without the grid fee, so the **Network fee** on the paired charger is the only thing added. A session with fine enough readings (Zaptec's energy details) is priced per interval, and one with only a total (Easee, NexBlue) is priced at the time-weighted average over the session. In both cases a missing price slot is shown as missing and never filled. If Tibber cannot be read (a revoked token, a rate limit, no network), the import still runs, the session is priced from your electricity settings, and Settings says why. The token is stored in the macOS Keychain and deleted by **Disconnect Tibber** or by erasing all data.

`priceInfoRange` stops at the slot running now, so a request that reaches past now also reads `priceInfo { today tomorrow }` for the rest of today and for tomorrow (published in the afternoon). Without that the Charging Planner sees no prices ahead and falls back to Elpriser. Each quarter-hour also carries Tibber's own level, which the Charging Planner shows beside "Now" and "Planned average". The home's price area and grid company come from its metering point; the grid company's fee is not published, so it stays the Network fee you type in. Hourly meter readings (`consumption`, about two months back) feed the Car Share of House Load rows in Log, Charging Trends. When the home has a production metering point (solar, typically), its hourly `production` is read the same way, two months back, and Charging Trends adds a **House Production** row over the hours the share covers. A home that reports no production gets no row.

Live house power comes from a Tibber Pulse (or the older Watty) reader paired to the home's meter. Hisingen asks the home first whether one is paired, and only then opens the API's websocket stream (`wss://api.tibber.com/v1-beta/gql/subscriptions`, the `graphql-transport-ws` protocol Tibber's own .NET SDK speaks). The charging card shows the house load from it exactly as the Perific lines do, plus the production the stream reports while the home is producing, with the same last-known rule: a frame older than three minutes keeps its figure with its age, and the momentary lines are left out. With a Perific meter connected, its house lines stay (they also read phases and today's totals) and only the production line comes from Tibber, because a meter's HAN port sees no production. When the home reports no reader, the line stays absent, Settings → Electricity → Electricity Supplier says **No Pulse paired**, and the API itself would refuse the subscription with "no active pulse devices found in home". The token is sent once, in the stream's handshake, and nothing else goes out.

It works with every charger connection, Home Assistant included: with Tibber connected, its own prices are used first and Home Assistant's `tibber.get_prices` is only the fallback.

Live checks: confirm that the home list shows your home, that a recent session's cost matches the Tibber app within the network fee, and that the first import after connecting prices sessions older than a day (Hisingen reads up to about 40 days of prices; against a real account the cursor paging reached back to the start of the subscription). With a Pulse paired, confirm the charging card's House line tracks the Tibber app within a few seconds and that Settings says **Reading live**; without one, that Settings says **No Pulse paired**. With a production meter, confirm the **House Production** row against the Tibber app's production total for the same days. The live stream has not been checked against a real Pulse here: the frame shapes follow Tibber's .NET SDK and the schema reference on developer.tibber.com.

## Connect a Perific house meter

A Perific (formerly Enegic) monitor on the electricity meter's HAN port can show what the whole house draws, next to the charger. This is optional and read only: Hisingen never writes to Perific, never touches its load balancer, and needs no Home Assistant and no paired charger.

1. Open **Settings, Electricity**, find **House Meter** and sign in with the account you use in the Perific app. The login is kept in the macOS Keychain and is never exported. With one meter on the account, Hisingen uses it. With several, pick one.
2. On the charging card, a muted line under the session figure reads **House 3.4 kW**. While the car charges and both readings are current, a second line splits it: **Car 2.3 kW, rest of the house 1.1 kW**. A **House Meter** disclosure lists voltage and current in each phase and the energy imported today (and exported, when there is any).
3. In **Log, Charging Trends**, Car Share of House Load reads the meter's hourly import when Tibber is not connected (or does not answer). Tibber stays first because it also reports what each hour cost. The row's information button says which meter the share came from.

What to know about the numbers:

- **Power is apparent power.** The monitor reports current and voltage per phase, not watts. Hisingen multiplies and adds them, so the figure can read slightly above the energy the meter bills when the power factor is poor.
- **Today's totals are the meter's own difference.** The monitor reports a running total at local midnight and another now, so today's imported and exported energy moves with every read, not every few minutes. History is read for the hourly trends, and for today only when the meter has no completed day yet.
- **A reading older than three minutes is shown as last known**, with its age, and the car split is left out. The monitor reports about every ten seconds and Hisingen reads every thirty.
- **Only the grid connection is seen.** The HAN port carries no solar production.
- **History starts when the monitor was registered.** The cloud answers one point per minute, and Hisingen keeps the readings taken on the hour.
- **The split is left out when it cannot be right**: when the car's power is more than a tenth above the house's, or either reading is not current.

How it talks to Perific: there is no public API and no local interface. The monitor reports to Enegic's cloud, and Hisingen reads the same cloud the Perific app does, with `PUT /createtoken` for the login (a token that lasts a year, sent bare in `X-Authorization`), `GET /getaccountoverview` for the meter, `PUT /getlatestpackets` for live readings and `PUT /getphasedata` for history. These are not vendor-documented. Everything here was checked against a live account on 2026-11-18 (a Perific One, firmware 4.5.15, packet version 3), but Enegic can change it without notice, and using it may not be something Perific supports. If it stops working, Hisingen shows the meter as unreachable and the rest of the app carries on.

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
- A charger integration in Home Assistant. NexBlue is matched by its entity names even without
  the device list; Easee and Zaptec are found through Home Assistant's device registry by their
  status, power and energy entities. Any charger that exposes a switch, a charging-state sensor,
  a power sensor and a session-energy sensor can be mapped by hand.
- A Home Assistant long-lived access token. Create one in your Home Assistant profile under
  **Security**. A token from an administrator also reads the device registry, which finds the
  serial number and groups Easee and Zaptec entities by device; a non-administrator token falls
  back to matching NexBlue entity names. Discovery maps a charging switch only when every option
  of its status sensor is a state Hisingen can read, because that sensor is what confirms a
  command. A charger whose states are not recognised is still listed for its readings, but its
  switch is left for you to map by hand.
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

### A second charger

An install can hold two chargers: pair the second one from **Settings → Home Charging → Add another
charger**. Both stay listed with their own vehicle, charge location and last reading, and each has
its own plan record.

One charger holds the live connection at a time — the one whose row is marked **Live connection**.
Selecting the other row switches the connection to it, and the charger left behind keeps its last
reading labelled with the time it was read. The app reads the other charger every few minutes while
a second one is paired, so both stay visible without two live connections.

The charging card follows the car: it shows the charger paired to that vehicle at its saved charge
location, and its commands go to that charger (switching the connection first when needed), so two
chargers are never commanded through each other's reading. Unpairing one leaves the other paired
and connected.

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

## Electricity prices and the Charging Planner

**Settings → Electricity** sets the country, either Sweden or another country.

* **Sweden, Automatic rate.** Charging is priced from the spot price for your zone (SE1 to SE4)
  plus your provider's markup, with optional tax and grid fee in öre/kWh and a VAT toggle. You
  choose the contract type: 15-minute price, as the market publishes it, or hourly price, which
  averages the four quarters in each hour. The provider list (Vattenfall, Fortum, E.ON, Tibber,
  Bixia, Greenely, Göteborg Energi, Skellefteå Kraft, Telge Energi, Jämtkraft, or other) only
  names the contract. It carries no prices, because markups differ per agreement. The price your
  settings produce is shown next to the controls.
* **Every other country.** A typed-in rate and the optional night tariff.

Hisingen uses the selected rate for charge-to-target estimates, session costs and totals in Log
and CSV exports. A connected Tibber home supplies prices for sessions it covers. Changing the markup re-prices past sessions that have a stored market cost.
Sessions the market prices do not cover keep their saved cost or your fixed rate.

The **Charging Planner** needs Sweden and its feature switch. It shows an hourly price curve and
the cheapest window to reach your target. Automatic charging commands are bound to the vehicle
the plan was calculated for. Choosing another country stops the planner and
keeps its settings for when Sweden is selected again. Spot prices come from
[Elpriset just nu.se](https://www.elprisetjustnu.se/), are fetched once a day after 14:15 and
exclude taxes and grid fees, so the markup you enter matters. Missing history is fetched, and
each zone refreshes on its own schedule.

**The window has a fixed end.** If you turn on **Auto-Start Charging in the Window**, Hisingen
sends the charge-now override when the window opens and records that window's end. If the car is
still charging when the end arrives — because it charged slower than the configured power — the
planner ends its override there rather than letting it run on to the charge limit in the hours
after the cheap window. The next plan is a new window, judged against the prices still ahead.
This is the honest limit of a menu-bar app: Hisingen cannot wake a Mac that is already asleep, so
the planner only acts while the Mac is awake.

**Keeping the Mac awake** is a separate opt-in toggle under **Settings → Automations**. It holds a
system sleep assertion from the moment a planned window is known until that window ends, so the
minute tick can send both the start and the stop. It is off by default, works only together with
**Auto-Start Charging in the Window**, and does not wake a sleeping Mac. Leaving it on can keep a
MacBook awake for most of the day, because a window is always somewhere ahead while the car is
below its target; that is the cost of not being able to schedule a wake.

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

Perific stays in charge of dynamic load balancing, and Hisingen never writes to it. When the
charger reports `lb_waiting` the card says **Waiting for available power**; charging well below the
session's own peak is reported as reduced power that load balancing can cause. An exact current
allocation would need a live, timestamped signal from Perific on your installation, and none is
assumed. The optional house meter (see Connect a Perific house meter) only reads what the whole
house draws.

On the installation this was built against, the Perific account lists the monitor and one Open
reporter (Perific's partner link, which is how NexBlue appears), and that reporter's own settings
say `LoadBalancingEnabled: false` with a 20 A rule on the monitor. NexBlue's own site setting is
also off. So limiting of the charger may not be coming from Perific there at all. Treat
`lb_waiting` as the charger's word, and confirm in the Perific and NexBlue apps which of them is
balancing before relying on the wording.

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

Load balancing itself is not read from Perific. Reduced charging and waiting are explained from the charger's own status and measured power. The optional house meter is a separate, read-only reading of the whole house.

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
