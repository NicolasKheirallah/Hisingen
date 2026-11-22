# Vehicle support and readings

[Supported models](#vehicle-support) · [Vehicle readings](#vehicle-readings) · [Remote controls](remote-controls.md) · [Documentation](README.md)

## Polestar and Volvo

|                         | Polestar                                | Volvo                                                                |
| ----------------------- | --------------------------------------- | -------------------------------------------------------------------- |
| **Setup**               | Sign in with your Polestar account      | Sign in with your Volvo ID, ready out of the box (own developer application optional) |
| **Battery EVs**         | Yes                                     | Yes                                                                  |
| **Fuel readings on plug-in hybrids and combustion cars** | Electric readings only | Where the API reports fuel data |
| **Multiple vehicles**   | Yes                                     | Yes                                                                  |
| **Vehicle location**    | Where available                         | Where available                                                      |
| **Remote controls**     | Experimental and vehicle-dependent      | API and vehicle-dependent                                            |
| **Vehicle images**      | Multiple exterior views where available | Volvo-provided imagery where available                               |

### Polestar

Polestar ID connects through the same vehicle services as the Polestar app. The separate
Developer Portal connection provides read-only telemetry. [Polestar setup](install.md#polestar-setup)

### Volvo

Volvo provides official developer APIs. Sign in with Volvo ID using the credentials Hisingen
supplies, or connect your own Volvo Cars Developer application. [Volvo setup](install.md#volvo-setup)

## Vehicle support

Hisingen recognises the vehicle families below. Feature availability still depends on the
model year, region, software and what the provider reports.

### Recognized Polestar models

* Polestar 1
* Polestar 2
* Polestar 3
* Polestar 4
* Polestar 5
* Polestar 6

Hisingen can identify the Polestar 1 and uses reported capabilities for available telemetry
and controls. The Polestar integration's powertrain readings cover its electric side.

### Recognized Volvo models

* XC40
* EX40
* C40
* EC40
* XC60
* XC90
* S60
* S90
* V60
* V90
* EX30
* EX90
* ES90

Other cars can appear when Volvo's API discovers them. If you've tested a model, year or region
that isn't listed, [report what worked](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=vehicle_compatibility.md).

## Vehicle readings

The readings depend on what the provider reports for your car.

### Battery & range

For electric and plug-in hybrid vehicles, Hisingen can show information such as:

* state of charge
* electric range
* charging state
* charger connection
* AC or DC charging
* charging power
* current and voltage
* charge target
* charge-target mode (Polestar): Daily, Long trip or Custom, shown beside the target on the
  charging card when the car names one
* "Last changed" date beside the charge target and current limit when the car last set them
  over 30 days ago, on the charging card, the limit steppers and the vehicle report
* charging-current limit
* estimated charging completion
* energy consumption
* energy used by driving, climate, battery conditioning and other loads, for manual trips,
  automatic trips and since the last charge (Polestar)
* battery discharge power limit and available energy, manual preconditioning and cold-battery
  status, when the car reports them (Polestar)
* one-tap amp presets (6/8/10/13/16 A) beside the current-limit slider
* saved charge location settings (Polestar): rename, per-location current limit,
  minimum charge level, optimised-charging mode, delete

The interface only shows values that make sense for the selected vehicle.

If a completed session at a known location peaks far below its usual level,
Hisingen flags it, often the first sign of a failing cable or derated charger.

Hisingen can also calculate an experimental battery State of Health estimate
from the telemetry it has observed. This is always labelled as a calculated
estimate, includes its input signals and confidence, and must not be confused
with a battery-management-system measurement or a warranty diagnosis. Exact
usable capacity and WLTP references can be entered per VIN in Settings.

The estimate uses two methods: the range shown at 100% charge, and high-confidence charging
sessions. When both agree within tolerance Hisingen shows a fused value, and when they disagree
it shows the conflict instead of hiding it behind one number. The uncapped range-based figure is
kept next to the displayed value, which is capped at 100%, so an understated WLTP reference stays
visible. The trend is fitted with a median-based slope that ignores a single bad range reading.
The range-based method applies to battery-electric cars with a known model reference, and to a
plug-in hybrid that has its own electric WLTP figure. An XC40 Twin Engine uses 45 km, the top of
its published 41–45 km electric range, never the battery-electric XC40's 570 km. That car starts
in Hybrid mode, and the uploaded full-charge figure is the lower Hybrid start value rather than
the Pure-mode figure this rating describes. The percentage therefore runs low, and Hisingen does
not correct it with a guessed offset. A reference you set for that VIN replaces the table. A
plug-in hybrid with no electric figure stays uncalculated. The charging-session method still
applies only to battery-electric cars.

### Fuel & hybrid information

Volvo support isn't limited to electric cars.

On compatible hybrid and combustion vehicles, Hisingen can also show:

* fuel level
* remaining fuel
* distance to empty
* fuel consumption
* combined battery and fuel information on plug-in hybrids

A combustion Volvo won't be shown a meaningless EV battery interface, and an EV won't be shown fuel information it doesn't have.

### Charging history

Hisingen can keep a local record of charging sessions.

Depending on the telemetry available, a session can include:

* starting battery level
* ending battery level
* estimated energy added
* charging duration
* peak charging power
* the calculation source and confidence
* the electricity tariff saved when charging began
* estimated charging cost

Charging data can also be exported for your own analysis.

The history dashboard shows detected trips five at a time with navigation to older pages. Charge
curves preserve the real observation timeline: rounded SoC is drawn as steps, missing intervals
are visibly broken, and the source/confidence badge explains how the energy total was derived.

Energy is integrated from observed charging power when coverage is sufficiently complete;
otherwise Hisingen falls back to the change in battery percentage and configured usable
capacity. The session shows which method was used. Costs retain the session's day/night tariff
and currency instead of being recalculated when today's settings change. These remain estimates
based on vehicle telemetry rather than utility-grade metering.

Detected trips can be tagged **Business** or **Private**, and a Monthly Mileage Report totals
the business/private distance split per month with CSV export. Tags are stored locally per
vehicle.

Public charging can be logged by hand from the **Charging Sessions** card: **Add Session**
records the charging place (home or public), a location, the start and end time, the energy, and
the price as a total, a price per kWh, or both. A stored session can be edited from its context
menu or the pencil in its detail card, so a public charge the car recorded without a price can be
corrected. The **Charging Trends** card separates **Home Charging** and **Public Charging** cost;
the two lines add up to the total. Sessions recorded automatically count as home until their
place is changed. Everything is stored locally and no provider is asked for a price.

A few more things that follow from the same history:

* scheduled charging says whether it will finish, including "cannot complete" and "smart
  charging will not finish", instead of collapsing every plan to "Scheduled"
* when the car is within 150 m of a saved charge location, the card reads "At <location> since
  <time>"
* History has a per-location charging cost table, grouped by currency
* the trip computer shows distance and average speed since the last charge, taken from the C3
  odometer reading

### Home charging and electricity

Pair NexBlue, Easee or Zaptec directly, or connect through Home Assistant. You can also price charging from a fixed tariff, Swedish spot prices or a connected Tibber home. [Home charging and electricity guide](home-charging.md)

Home Assistant discovery reads NexBlue's entity names without any special token; with an
administrator token it also groups Easee and Zaptec entities by device and maps their status,
power and energy readings. A charging switch is only mapped automatically when the status sensor
can confirm a command, so discovery never offers a write it cannot check; a charger with
unrecognised states is still listed for its readings and can be mapped by hand.

When Open-Meteo answers, the **Charging Planner** draws a **solar forecast** line of global
shortwave radiation for the next day at the car's location, with its peak time. It is radiation,
not panel output: Hisingen has no array or inverter figures, so it never turns the forecast into
kWh. A saved **Electricity Maps** token adds a **live grid carbon** line under the plan, with the
provider named beneath it. Without a token, or whenever the provider fails, the line stays absent
rather than showing a guessed figure. The typed grid intensity in Settings remains the input for
the History emissions estimate.

### Doors, windows & locks

Hisingen can show the state reported for things such as:

* central locking
* individual doors
* windows
* hood
* tailgate
* charge flap
* fuel filler
* sunroof
* alarm

If the car doesn't report something, Hisingen doesn't quietly turn that missing information into “closed” or “locked”.

### Vehicle health

Depending on the car, Hisingen can surface:

* tyre warnings
* individual tyre-pressure information
* exterior-light warnings
* fluid warnings
* 12 V battery warnings
* service information
* service countdown
* odometer
* trip meters
* average speed
* consumption data
* battery and powertrain health information

Different vehicle platforms expose different levels of detail.

On top of the live readings Hisingen keeps some local context:

* **Tyres.** A local pressure history with a four-tyre chart and a possible-slow-leak hint.
  Measured pressures are compared with the car's own reported reference pressures.
* **Warnings.** A timeline records when each warning first appeared and when a report that
  covers it cleared it. Failed exterior lamps are named individually under the lighting row.
* **Service.** The next service date is estimated from the last 30 days of driving.
* **Usage mode.** The reported vehicle usage mode shows in the connectivity details, including on
  vehicles without separate network diagnostics.
* **Weight.** The reported gross vehicle weight shows on the Car specs card (Polestar).
* **Reminders.** The service, tyre and low-battery warning surfaces each offer an Add Reminder
  action that writes a reminder through macOS Reminders with a default due date, and the
  plug-in alert can create it automatically once you opt in. See
  [Using Hisingen](using-hisingen.md#reminders).

### Climate

Hisingen can show climate information and, where supported, control climatization remotely.

Depending on the vehicle this can include:

* current climate state
* heating or cooling activity
* cabin-temperature information
* remaining runtime
* climate timers
* seat-heating capabilities
* steering-wheel heating
* cabin cleaning

Climate is a good example of why Hisingen adapts to the individual car.

A Polestar 2, for example, may allow climatization to be started without exposing the same temperature controls available on newer platforms.

Instead of presenting controls that won't work, Hisingen adjusts the interface to what's actually available.

On Polestar the climate card shows the climatization type and the maximum preconditioning
runtime the car reports, instead of one claim that fits every model. When a session starts or
fails, Hisingen explains why, including the reported error reasons. Seat and steering-wheel
heating are shown as requests, and an unspecified request is kept apart from an explicit off,
because automatic heating may differ from what was asked for.

Climate timers show whether they repeat weekly. Hisingen reads that flag back for the timers it
writes itself, instead of guessing from the weekday list. The climate card also names the heater
type the car reports and whether the car heats the seats and steering wheel on its own in cold
weather.

Before a scheduled departure, Hisingen can hint at frost or a cold battery using an hourly
forecast on the climate card. The weather readout adds one line of climate advice when the
forecast before the departure is cold, wet or windy. The next departure comes from the car's own
departure timers, or from the calendar preconditioning schedule when it is enabled and its next
event is sooner; with no departure time or no forecast hour at the departure, nothing is shown.
A notice appears once per climate session when the run time is nearly used up or the battery is
too low.

### Location

When enabled and available from the vehicle provider, Hisingen can show the car's latest reported location as a street **address** (with precise coordinates below), open it in Apple Maps, and chart cabin temperature trends where the vehicle reports them.

Vehicle location should be treated as the **latest location reported by the car**, not as guaranteed real-time tracking.

A parked or sleeping vehicle may report an older position.

### Weather at the car

Vehicle weather is optional.

When enabled, Hisingen can use the vehicle's reported location to show local weather around the car.

Weather data comes from [Open-Meteo](https://open-meteo.com/).

Because coordinates are needed to retrieve local weather, the vehicle's latitude and longitude are sent to Open-Meteo while this feature is enabled.

The hourly forecast that drives the pre-departure hints is fetched in the same request as the
current weather. Both carry wind speed, gusts and precipitation, which the weather readout shows
beside the temperature; wind speeds follow the reader's distance unit, and precipitation is
millimetres of water regardless of whether it falls as rain or snow.

Live check: the request shape was verified against Open-Meteo without a key, but the readout's
calendar-based advice line has not been exercised against a real calendar and a live refresh.

### Vehicle software

Where the provider exposes it, Hisingen can show vehicle software and update-related information.

Polestar currently exposes more software information to Hisingen than Volvo's developer APIs do, so this section can look different between the two brands.

When a car does not report update status at all, the card says "Not reported by this vehicle"
instead of claiming that no update is available.

### Car tab and the capabilities inspector

The Car tab is the car's technical passport: identity and specifications on top, then the
capabilities the backend reports for this exact vehicle.

* **Specifications.** Model, year, battery capacity, charge port, reported gross vehicle weight
  and, on Polestar, the readable groups of the `visual_id` string (vehicle type, front grille
  variant, model year). Groups whose code table is not verified stay positional.
* **Service date.** "Due around <day> at your current driving rate" appears when the car reports
  a distance to service and the local store holds at least a week of odometer samples from the last
  30 days. It is a planning hint, shown as day and month only.
* **Export Factory Passport (CSV)** writes the specifications to a file.
* **Export Handover Pack…** is described under [Your data](using-hisingen.md#your-data).

The capabilities card lists what the provider says the car supports. Three disclosure groups sit
under it, and each row appears only when the backend actually sent the field:

* **Backend Control Settings:** charging locations, timers per location, departure times per
  location and climate timers the car allows, plus whether it supports per-location departure
  times, current limits and optimised charging.
* **Backend Reporting:** statements the car makes about itself, such as reporting flags,
  notification settings, end-of-ownership actions, account linking, parking-assistance type, trip
  reporting, device pairing, bidirectional charging and the preconditioning duration. These are
  not controls.
* **Unwired Backend Fields:** wire fields the backend sends that no control uses yet, shown raw so
  new backend data stays visible. Most `GetMyCars` tags now have a name, so this list is short.
  Unknown fields on the air-quality, charge-target and charging-current reads are kept the same
  way.

Plug and charge is claimed only when the backend also sends the plug-and-charge identifier,
because the wire flag and the REST value disagree on the car this was tested on.

[Remote controls](remote-controls.md) · [Product tour](product-tour.md)
